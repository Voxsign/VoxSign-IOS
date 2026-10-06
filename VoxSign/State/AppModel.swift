//
//  AppModel.swift
//  VoxSign
//
//  Service integration + state orchestration (mirrors web/app.js). Pure judgments / state machines
//  live in VSLogic and SSEParser; this class only holds state, orchestrates HTTP/SSE, and drives the UI.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Chat flow model

/// One row in the chat flow (user / harness bubble, typing dots, exec card, receipt card).
enum ChatRow: Identifiable {
    case user(Bubble)
    case harness(Bubble)
    case typing
    case execCard(ExecCardState)
    case receipt(ReceiptRow)

    var id: UUID {
        switch self {
        case .user(let b), .harness(let b): return b.id
        case .typing: return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .execCard(let s): return s.id
        case .receipt(let r): return r.id
        }
    }
}

/// Receipt row: with a stable id (fixes the old bug where .receipt used a fresh UUID each render, breaking ForEach identity).
struct ReceiptRow: Identifiable {
    let id = UUID()
    let receipt: Receipt
    let undo: UndoInfo
    let badges: [Badge]
}

struct Bubble: Identifiable {
    let id = UUID()
    var text: String
    var badges: [Badge] = []
    var fromVoice: Bool = false
    /// UI v3: recorded seconds for a voice message (shown in the bubble, e.g. "3s").
    var voiceSeconds: Int? = nil
    /// v2.4: resource attachments submitted with this message.
    var attachments: [Attachment] = []
    /// v2.4: tokens consumed by this reply (shown on the harness bubble).
    var costTokens: Int? = nil
    /// v2.4: message timestamp (for session history ordering/display).
    var timestamp: Date = Date()
}

/// One stage row in the exec card.
struct StageState: Identifiable {
    let id = UUID()
    let name: String
    var done: Bool = false
    var active: Bool = false
}

struct ExecCardState: Identifiable {
    let id = UUID()
    var stages: [StageState]
}

// MARK: - Harness state (UI v3 top-bar 5pt status dot, derived from real state)

enum HarnessState: Equatable {
    case idle       // gray: no task
    case busy       // breathing blue: task running
    case decision   // orange: waiting for user confirm/select
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {

    // Chat flow
    @Published var rows: [ChatRow] = []
    @Published var decision: DecisionPoint? = nil
    @Published var systemBar: SystemBarInfo? = nil

    /// UI v3: data source for the top-bar status dot (busy / decision / idle).
    @Published var harnessState: HarnessState = .idle

    // Role collapsed bar
    @Published var activeRole: String = "executor"
    @Published var roleBarOpen: Bool = false
    @Published var roles: [RoleInfo] = [
        RoleInfo(id: "planner", label: "Planner", active: false),
        RoleInfo(id: "executor", label: "Executor", active: true),
        RoleInfo(id: "verifier", label: "Verifier", active: false)
    ]

    // Settings
    @Published var showSettings: Bool = false
    /// V6: the "switch machine" panel opened by tapping the top-bar machine name.
    @Published var showMachinePicker: Bool = false
    @Published var statusLine: String = ""
    @Published var inputText: String = ""

    // v2.4 multi-session (hidden by default, not on the main screen)
    @Published var showSessions: Bool = false
    @Published var currentSessionID: String = ""
    var sessions: [ChatSession] { SessionStore.shared.sessions }

    /// V6.3 top-bar sub-info: the machine name actually connected to (follows connection state; shows "Offline" when not online).
    @Published var machineLabel: String = "VoxSign Cloud"
    private var machineLabelSub: AnyCancellable?

    // v2.4 attachments: pending attachments on the input bar
    @Published var pendingAttachments: [Attachment] = []

    /// Diagnostic line (M7 on-device troubleshooting): shows the latest poll status/error on screen, avoiding a black-box "Processing…".
    @Published var diagLine: String = ""

    /// T2 scroll fix: incremented after every append/replace; RootView observes it to scroll to bottom.
    /// Observing rows.count previously missed the continuous "remove typing -> append row" sequence,
    /// so the user spoke and couldn't see the harness's follow-up.
    @Published var scrollTick: Int = 0

    /// T2 voice-remainder fix: for 1.5s after a voice submit, suppress ASR partials writing back to the
    /// input box; otherwise old audio tails / new fragments get recognized as characters and reappear.
    @Published var voiceCooldown: Bool = false

    // Current task (for interrupt / resume)
    private var currentTaskId: String?
    private var currentView: TaskView?
    private var sseTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastSeq: Int = 0
    private var execCardRowId: UUID?

    /// One-turn ASR result (P1 one-turn-one-clear: cleared on send / new turn). Written by SpeechRecognizer.
    var pendingVoiceTranscript: String = ""

    private let api = APIClient.shared
    private let sse = SSEClient.shared
    /// v2.3: this turn's submit time (for rendering "Processed in Xs").
    private var lastSubmitAt = Date()
    /// T2 connectivity: subscription to auto-flush on network recovery (cleared on cancel).
    private var connSub: AnyCancellable?

    init() {
        // v2.4 multi-session: ensure at least one session, and restore the current chat rows from its history.
        // UI v3 (Doubao-style empty state): a new session shows only one gray empty-state line.
        SessionStore.shared.ensureInitialSession()
        currentSessionID = SessionStore.shared.currentSessionID
        rows = Self.messagesToRows(SessionStore.shared.loadMessages(for: currentSessionID))

        // T2 Doubao-style: on network recovery -> auto-flush the offline queue (voice commands never lost).
        connSub = ConnectivityService.shared.onOnline { [weak self] in
            guard let self = self else { return }
            Task { await self.flushQueue() }
        }

        // V6.3 top-bar machine name: refresh on (connection state + mode + active server) —
        // the name must match the actual connection target (it only changes when you really switch; default = cloud).
        let store = SettingsStore.shared
        machineLabelSub = Publishers.CombineLatest3(store.$mode,
                                                   store.$activeServerID,
                                                   ConnectivityService.shared.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMachineLabel() }
        refreshMachineLabel()
        // T2 Doubao-style: when ASR recognizes a complete sentence -> auto-submit (speak-and-go, no button tap).
        #if canImport(Speech)
        SpeechRecognizer.shared.onFinalSegment = { [weak self] text in
            guard let self = self, !text.isEmpty else { return }
            Task { @MainActor in self.sendVoice(text) }
        }
        #endif
    }

    /// T2 voice-specific send: same path as keyboard send, but the bubble is flagged fromVoice and the one-turn buffer is cleared.
    /// v2.1: at a decision point voice prefers spoken answers (I06/I13/I17); very short filler words are not submitted.
    func sendVoice(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        #if canImport(Speech)
        SpeechRecognizer.shared.resetRound()
        #endif
        // T3 Doubao-style: when the user starts speaking, immediately interrupt the previous TTS (listen to the user first).
        VoiceOutputService.shared.stop()

        // v2.3 user directive (2026-10-04): "remove all interception, don't decide for the user":
        // the local spoken-answer interception layer (confirm/option/undo/negative-word checks) is removed —
        // every voice utterance goes straight to the backend as a new command, with no confirmation prompts,
        // so normal long sentences containing negations are not falsely blocked. Filler filtering is kept to avoid backend follow-up loops.
        if VSLogic.isNoiseWord(t) {
            DiagLogger.shared.log("ASR", "filler ignored: \(t)")
            return
        }
        appendUser(t, fromVoice: true)

        if VSLogic.isInterruptPhrase(t),
           let id = currentTaskId, let view = currentView,
           !VSLogic.isTerminal(view.status) {
            maybeInterrupt(taskId: id, view: view)
            return
        }
        submit(t)
    }

    /// v2.1 spoken-answer decision: confirm/option/undo. Returns true if consumed as a spoken answer (not submitted as a new task).
    private func handleVoiceDecision(_ t: String) -> Bool {
        // I17 voice undo chain: say "undo" to roll back the last reversible operation.
        if VSLogic.isUndoPhrase(t) {
            if let row = rows.last, case .receipt(let r) = row, r.undo.show {
                speak("OK, undoing the last operation.")
                rollback()
                return true
            }
            return false   // nothing to undo -> not treated as undo, goes through as a normal command
        }
        guard let d = decision else { return false }
        switch d.kind {
        case .confirm:
            // I13 risk tier: high-risk actions (commit/push/merge/deploy/delete...) require a button; spoken answers do not apply.
            let probe = (currentView?.receipt ?? "") + (currentView?.question ?? "")
            if VSLogic.isHighRiskAction(probe) {
                speak("This is a high-risk operation; please confirm with the button below.")
                return true
            }
            if VSLogic.isAffirmPhrase(t) { answer("execute"); return true }
            if VSLogic.isNegativePhrase(t) { answer("reject"); return true }
            return false
        case .ask:
            if let hit = d.options.first(where: {
                t.contains($0.label) || $0.label.contains(t) || t.contains($0.id) || $0.id.contains(t)
            }) {
                answer(hit.id)
                return true
            }
            // "anything / whatever / your call" -> first option (Doubao-style natural answer).
            if VSLogic.isAffirmPhrase(t), let first = d.options.first {
                answer(first.id)
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: - Send entry
    //
    /**
     * 【Pseudocode logic layer】(required: send -> interrupt check -> submit)
     *   send(text):
     *     if isInterruptPhrase(text) and a task is running (currentTaskId not terminal):
     *       -> maybeInterrupt(text) (red system bar + POST /v1/tasks/{id}/cancel)
     *     else:
     *       → submit(text)
     */
    func send() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        let atts = pendingAttachments
        appendUser(text, fromVoice: false, attachments: atts)

        if VSLogic.isInterruptPhrase(text),
           let id = currentTaskId, let view = currentView,
           !VSLogic.isTerminal(view.status) {
            maybeInterrupt(taskId: id, view: view)
            return
        }
        submit(text, attachments: atts)
    }

    // MARK: - Submit -> SSE flow
    //
    /**
     * 【Pseudocode logic layer】(required: submit -> SSE events -> decision flow)
     *   submit(text):
     *     reqId = genRequestId()                 // client idempotency key
     *     POST /v1/tasks {text,request_id} → {task_id}
     *     show typing dots
     *     openSSE(task_id)
     *   openSSE(id):
     *     GET /v1/tasks/{id}/events?after=lastSeq (reconnect)
     *     for await ev:
     *       stage     -> advance exec card + syncRole
     *       need_ask  -> decision = ask(question, options) (stop at the confirm gate)
     *       need_confirm → decision = confirm(question)
     *       done      -> stop stream; build TaskView from the done event -> render receipt card + badges
     *       failed    -> error bar
     *       interrupt -> red system bar with three semantics
     *       canceled  -> terminal error bar
     *     stream error (not terminal) -> reconnect with ?after=lastSeq
     *   answer(id, ans):
     *     POST /v1/tasks/{id}/answer {answer:ans}
     *     -> clear decision; reopen SSE(id) to continue
     */
    func submit(_ text: String, attachments: [Attachment] = []) {
        let reqId = VSLogic.genRequestId()
        // v2.3 (user request: WeChat-style "Processed in Xs"): record submit time; compute duration on done.
        lastSubmitAt = Date()
        // UI v3: task starts -> top-bar dot busy (breathing blue).
        harnessState = .busy
        // v2.2: clear the previous turn's residual intermediate state (typing/execCard) before this turn — back-to-back speech does not stack "Thinking".
        closeExecCard()
        rows.append(.typing)
        armLongTaskTimers()
        Task {
            do {
                // T2 connectivity: probe before submit — if offline, don't wait 15s, go straight to the offline queue.
                guard await ConnectivityService.shared.isReachable() else {
                    removeTyping()
                    if DeliveryQueue.shared.enqueue(PendingSubmission(requestId: reqId, text: text, mode: "text")) {
                        DiagLogger.shared.log("QUEUE", "offline enqueue reqId=\(reqId) queue=\(DeliveryQueue.shared.count)")
                        appendHarness("You are offline (\(ConnectivityService.shared.lastError)). The command was added to the offline queue (\(DeliveryQueue.shared.count) pending) and will be sent automatically once you are online.",
                                      view: TaskView(status: "canceled"))
                    } else {
                        appendHarness("You are offline and the offline queue is full; please retry once you are online.",
                                      view: TaskView(status: "canceled"))
                    }
                    return
                }
                let res = try await api.submitTask(text: text, requestId: reqId, attachments: attachments)
                // v2.4: clear pending attachments on successful submit (offline-queue/failure branches keep them; attachments ride the online submit path).
                pendingAttachments = []
                removeTyping()
                // Multi-task hardening: before a new task clears the previous unresolved decision and exec-card tracking,
                // so leftover SSE/poll state cannot misread the new task as the old one.
                decision = nil
                execCardRowId = nil
                currentTaskId = res.taskId
                // D0：seq 作用域 = per-task_id 从 0 计数。新任务开始前必须重置 lastSeq，
                //     否则上一任务的 lastSeq 会作为 ?after= 传给本任务 → 服务端只重放 seq>old，
                //     本任务从 seq=1 起的早期事件被全部跳过（执行卡/回执漏渲染）。
                //     answer() 续跑同一任务时不走到这里，保留累计 lastSeq 供断线重连。
                lastSeq = 0
                currentView = TaskView(taskId: res.taskId, status: res.status)
                ensureExecCard()
                DiagLogger.shared.log("SUBMIT", "new task task=\(res.taskId) status=\(res.status ?? "-") reqId=\(reqId)")
                // P0: decisions are driven by polling GET /v1/tasks/{id} (matching web/app.js; evidence from the task json);
                //     SSE in parallel only drives the exec-card stage highlight (P2). They don't conflict: polling stops at a terminal/decision point.
                startFlow(taskId: res.taskId)
            } catch {
                // T1 background capability: submit failure (network loss / unreachable / background suspended) -> enqueue;
                // on network recovery it is replayed idempotently by request_id; voice input is never lost.
                removeTyping()
                if DeliveryQueue.shared.enqueue(PendingSubmission(requestId: reqId, text: text, mode: "text")) {
                    DiagLogger.shared.log("QUEUE", "submit failed, enqueued reqId=\(reqId) queue=\(DeliveryQueue.shared.count) err=\(error.localizedDescription)")
                    appendHarness("The network is temporarily unreachable; your message was added to the offline queue (\(DeliveryQueue.shared.count) pending) and will be sent automatically once it recovers.",
                                  view: TaskView(status: "canceled"))
                } else {
                    appendHarness("Submit failed: \(error.localizedDescription) (check the ⚙ server address/token in the top right)",
                                  view: TaskView(status: "canceled"))
                }
            }
        }
    }

    /// T1 background: manually trigger a queue flush (shared by the network-recovery callback and the Settings "Flush" button).
    /// - Returns: number delivered this pass.
    @discardableResult
    func flushQueue() async -> Int {
        let n = await DeliveryQueue.shared.flush()
        if n > 0 {
            DiagLogger.shared.log("QUEUE", "flushed \(n), remaining \(DeliveryQueue.shared.count)")
            appendHarness("Flushed \(n) offline queue item(s).", view: TaskView(status: "done"))
        }
        return n
    }

    /// Dual-stream orchestration for one task: SSE stage stream + polling decisions.
    private func startFlow(taskId: String) {
        openSSE(taskId: taskId)
        startPolling(taskId: taskId)
    }

    /**
     * 【Pseudocode logic layer】(required: poll tick -> decision routing)
     *   startPolling(id): GET /v1/tasks/{id} every ~900ms
     *   tick(view):
     *     running      -> sync role; advance the exec card; keep polling
     *     need_ask     -> stop polling; collapse the exec card; decision = ask(question, options)
     *     need_confirm -> stop polling; collapse the exec card; decision = confirm(question)
     *     done         -> stop polling; close SSE; render the receipt card
     *     canceled/interrupted -> stop polling; error bar
     *   Polling stops at the first "one decision point per screen" and waits; answer() resumes.
     */
    private func startPolling(taskId: String) {
        pollTask?.cancel()
        DiagLogger.shared.log("POLL", "start polling task=\(taskId) interval 900ms")
        var failCount = 0
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    let view = try await api.fetchTask(taskId)
                    failCount = 0
                    DiagLogger.shared.log("POLL", "task=\(taskId) status=\(view.status ?? "nil") options=\(view.options?.count ?? -1) question=\(view.question ?? "-")")
                    await MainActor.run {
                        // T2 UI simplification: normal polling no longer writes the diagnostic line (no more
                        // "poll: running" spam); only terminal/decision points leave a trace; failures show in catch below.
                        if view.status != "running" {
                            self.diagLine = "poll: \(view.status ?? "?")"
                        }
                        self.route(polled: view)
                    }
                    if isPollTerminal(view.status) {
                        DiagLogger.shared.log("POLL", "terminal/decision reached, stop polling task=\(taskId)")
                        return
                    }
                } catch {
                    failCount += 1
                    DiagLogger.shared.log("POLL", "poll attempt \(failCount) failed: \(error.localizedDescription)")
                    await MainActor.run {
                        self.diagLine = "poll failed x\(failCount): \(error.localizedDescription)"
                    }
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    private func isPollTerminal(_ status: String?) -> Bool {
        guard let s = status else { return true }
        return s != "running"
    }

    @MainActor
    private func route(polled view: TaskView) {
        guard let id = currentTaskId, id == view.taskId else {
            DiagLogger.shared.log("ROUTE", "skip poll: taskId mismatch current=\(currentTaskId ?? "-") polled=\(view.taskId ?? "-")")
            return
        }
        currentView = view
        switch view.status {
        case "running":
            DiagLogger.shared.log("ROUTE", "running -> keep polling")
            harnessState = .busy
            syncRole(VSLogic.roleForStatus(view.status))
            applyExecProgress(forStatus: view.status)
        case "need_ask", "need_confirm":
            DiagLogger.shared.log("ROUTE", "\(view.status) -> render decision question=\(view.question ?? "-") options=\(view.options?.count ?? 0)")
            stopPolling()
            applyExecProgress(forStatus: view.status)
            closeExecCard()
            // UI v3: waiting for confirm/select -> top-bar dot decision (orange).
            harnessState = .decision
            decision = VSLogic.nextDecisionPoint(view)
            // T3 Doubao-style: speak the question when the user must confirm/select (answer without looking).
            if let q = view.question, !q.isEmpty {
                speak(q)
            }
            DiagLogger.shared.log("ROUTE", "decision.kind=\(String(describing: decision?.kind)) options=\(decision?.options.count ?? 0)")
        case "done":
            DiagLogger.shared.log("ROUTE", "done → 回执 reply=\(view.reply == nil ? "无" : "有")")
            stopPolling()
            sseTask?.cancel()
            // UI v3: task done -> top-bar dot back to idle (gray).
            harnessState = .idle
            syncRole(VSLogic.roleForStatus(view.status))
            closeExecCard()
            decision = nil
            // D0：done 渲染统一走 renderDone（reply 优先 / receipt 回退 / 都空则诚实文案），
            //     不再本地伪造"完成（server 已返回 done）"。
            renderDone(view)
        case "canceled", "interrupted":
            DiagLogger.shared.log("ROUTE", "\(view.status) -> error bar")
            stopPolling()
            closeExecCard()
            // UI v3: task ended -> top-bar dot back to idle (gray).
            harnessState = .idle
            if systemBar == nil {
                decision = VSLogic.nextDecisionPoint(view)
            }
        default:
            DiagLogger.shared.log("ROUTE", "unknown status=\(view.status ?? "nil") -> no action (swallowed?)")
            break
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// P2: advance the exec card by status (need_ask/confirm -> confirm gate; done -> all checks).
    private func applyExecProgress(forStatus status: String?) {
        let (doneCount, _) = VSLogic.execProgress(forStatus: status)
        guard doneCount > 0 else { return }
        for i in rows.indices {
            if case .execCard(var st) = rows[i] {
                for j in st.stages.indices {
                    st.stages[j].done = (j < doneCount)
                    st.stages[j].active = false
                }
                rows[i] = .execCard(st)
            }
        }
    }

    /// SSE consecutive-failure count (T2: exponential backoff + cap, to avoid infinite "reconnecting" spam).
    private var reconnectFailures = 0

    private func openSSE(taskId: String) {
        sseTask?.cancel()
        reconnectFailures = 0
        sseTask = Task {
            // Simple reconnect loop: if not terminal, reconnect with after=lastSeq.
            while !Task.isCancelled {
                do {
                    let stream = sse.events(taskId: taskId, after: lastSeq)
                    for try await ev in stream {
                        if Task.isCancelled { break }
                        lastSeq = max(lastSeq, ev.seq ?? lastSeq)
                        handle(event: ev, taskId: taskId)
                        if ev.isTerminal {
                            return
                        }
                    }
                    return // stream ended normally (terminal handled)
                } catch {
                    // T2: exponential backoff reconnect (0.8s->1.6s->... capped at 4s); stop after 5 consecutive failures.
                    // v2.2 fix (user reported "nothing at all"): reconnect notices no longer enter the chat flow —
                    // they are only logged; the top pill reflects ConnectivityService live, avoiding spam over replies.
                    reconnectFailures += 1
                    DiagLogger.shared.log("SSE", "reconnecting failures=\(reconnectFailures) err=\(error.localizedDescription)")
                    if reconnectFailures >= 5 {
                        DiagLogger.shared.log("SSE", "stopping after 5 reconnect failures, task=\(taskId)")
                        stopPolling()
                        return
                    }
                    let delay = min(Double(reconnectFailures) * 0.8, 4.0)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Task.isCancelled { return }
                }
            }
        }
    }

    private func handle(event: SSEEvent, taskId: String) {
        switch event {
        case .stage(_, let role, _, let step):
            if let r = role { syncRole(r) }
            if let step = step { advanceExec(toStage: step) }

        case .ask(_, let question, let options):
            currentView = TaskView(taskId: taskId, status: "need_ask",
                                   question: question, options: options)
            closeExecCard()
            decision = VSLogic.nextDecisionPoint(currentView!)
            // T1: local notification when backgrounded/locked (foreground is handled by the UI).
            NotificationService.shared.routeEvent("need_ask", taskId: taskId, seq: 0,
                                                  payload: ["question": question ?? ""])

        case .confirm(_, let question):
            currentView = TaskView(taskId: taskId, status: "need_confirm", question: question)
            closeExecCard()
            decision = VSLogic.nextDecisionPoint(currentView!)
            NotificationService.shared.routeEvent("need_confirm", taskId: taskId, seq: 0,
                                                  payload: ["question": question ?? ""])

        case .done(_, let receipt, let attribution, let reversible, let role, let reply):
            let view = TaskView(taskId: taskId, status: "done",
                                 receipt: receipt, attribution: attribution,
                                 reversible: reversible, reply: reply)
            currentView = view
            if let role = role { syncRole(role) }
            closeExecCard()
            decision = nil
            renderDone(view)
            NotificationService.shared.routeEvent("done", taskId: taskId, seq: 0, payload: [:])

        case .failed(_, let error):
            currentView = TaskView(taskId: taskId, status: "canceled", error: error)
            closeExecCard()
            decision = DecisionPoint(kind: .error, message: error ?? "Execution failed")
            NotificationService.shared.routeEvent("failed", taskId: taskId, seq: 0,
                                                  payload: ["error": error ?? ""])

        case .interrupt(_, let applied, let notApplied, _):
            // Three semantics -> red system bar (applied / not executed / undoable).
            var base = VSLogic.interruptSystemBar(currentView)
            if !applied.isEmpty { base.active = applied }
            if !notApplied.isEmpty { base.blocked = notApplied }
            systemBar = base

        case .canceled:
            currentView = TaskView(taskId: taskId, status: "canceled")
            closeExecCard()
            if systemBar == nil {
                decision = DecisionPoint(kind: .error, message: "Task canceled")
            }
            NotificationService.shared.routeEvent("canceled", taskId: taskId, seq: 0, payload: [:])

        case .unknown:
            break
        }
    }

    // MARK: - Answer / resume

    func answer(_ ans: String) {
        guard let id = currentTaskId else { return }
        decision = nil
        // UI v3: after answering the task resumes -> top-bar dot busy (blue).
        harnessState = .busy
        Task {
            do {
                try await api.answer(id, ans)
                ensureExecCard()
                startFlow(taskId: id)   // resume after need_ask / need_confirm approval
            } catch {
                appendHarness("Answer failed: \(error.localizedDescription)", view: TaskView(status: "canceled"))
            }
        }
    }

    // MARK: - Undo (rollback)

    func rollback() {
        guard let id = currentTaskId else { return }
        Task {
            do {
                let restored = try await api.rollback(id)
                appendHarness("Undone: \(restored ?? "restored")",
                              view: TaskView(status: "done", reversible: false))
            } catch {
                appendHarness("Undo failed: \(error.localizedDescription)",
                              view: TaskView(status: "canceled"))
            }
        }
    }

    // MARK: - Interrupt: say "stop" -> red system bar
    //
    /**
     * 【Pseudocode logic layer】(required: stop -> applied / not executed / continue-or-undo)
     *   maybeInterrupt(taskId, view):
     *     1. systemBar = VSLogic.interruptSystemBar(view)
     *        - active: applied (list the action if a receipt exists, else "no changes yet")
     *        - blocked: not executed (later stages aborted)
     *        - actions: ['Undo' (if reversible), 'Continue']
     *     2. POST /v1/tasks/{taskId}/cancel to really stop (404/405 falls back to legacy /v1/cancel)
     *     3. when the SSE interrupt event arrives, refresh the system bar's three semantics
     *     Edge: cancel endpoint fails -> show only the system bar, do not block the user.
     */
    private func maybeInterrupt(taskId: String, view: TaskView) {
        systemBar = VSLogic.interruptSystemBar(view)
        sseTask?.cancel()
        stopPolling()
        Task {
            do {
                try await api.cancel(taskId)
            } catch {
                // UI bar only; do not block the user
            }
        }
    }

    func closeSystemBar() { systemBar = nil }

    // MARK: - Role bar

    private func syncRole(_ statusOrRole: String) {
        // stage events carry role directly; status words are resolved via roleForStatus.
        let roleId: String
        if ["planner", "executor", "verifier"].contains(statusOrRole) {
            roleId = statusOrRole
        } else {
            roleId = VSLogic.roleForStatus(statusOrRole)
        }
        activeRole = roleId
        for i in roles.indices { roles[i].active = (roles[i].id == roleId) }
    }

    // MARK: - Settings

    func testConnection() {
        statusLine = "Connecting…"
        Task {
            do {
                let s = try await api.status()
                statusLine = "OK · v\(s.version ?? "?") · tasks=\(s.tasks ?? -1)"
            } catch {
                statusLine = "Failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Chat flow rendering helpers

    private func appendUser(_ text: String, fromVoice: Bool, attachments: [Attachment] = []) {
        autoNameIfNeeded(text)
        var bubble = Bubble(text: text, fromVoice: fromVoice, attachments: attachments)
        #if canImport(Speech)
        if fromVoice, SpeechRecognizer.shared.lastHoldSeconds > 0 {
            bubble.voiceSeconds = SpeechRecognizer.shared.lastHoldSeconds
        }
        #endif
        rows.append(.user(bubble))
        scrollTick += 1
    }

    /// V6.2 auto-naming: if the current session still has the default title ("New Chat"/empty),
    /// generate a title from the first user message. Local rule (VSLogic.autoTitle): first 12 chars + '…'.
    private func autoNameIfNeeded(_ text: String) {
        guard let s = SessionStore.shared.currentSession,
              s.title == "New Chat" || s.title.isEmpty else { return }
        let name = VSLogic.autoTitle(from: text)
        SessionStore.shared.renameSession(id: s.id, title: name)
    }

    /// T3 Doubao-style: speak the harness's "real reply" (completion/receipt/decision); system hints are not spoken.
    /// v2.1 adaptive speech: short text read fully; long text reads a summary + 'see screen' hint.
    private func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if t.count > 80 {
            let head = String(t.prefix(80))
            VoiceOutputService.shared.speak(head + ". This is long; see the screen for details.")
        } else {
            VoiceOutputService.shared.speak(t)
        }
    }

    private func appendHarness(_ text: String, view: TaskView, spoken: Bool = false) {
        rows.append(.harness(Bubble(text: text, badges: VSLogic.compressBadges(view))))
        scrollTick += 1
        if spoken { speak(text) }
    }

    private func removeTyping() {
        longTaskTimer?.cancel()
        typingText = "Thinking…"
        rows.removeAll {
            if case .typing = $0 { return true }
            return false
        }
    }

    // MARK: - v2.1 I18 long-task hint escalation (5s -> 10s)

    /// Dynamic thinking-state text (shown by TypingView).
    @Published var typingText = "Thinking…"
    private var longTaskTimer: Task<Void, Never>?

    /// Starts after submit: at 5s escalate to "Still thinking, almost there…"; at 10s to "This is taking a while; I'll notify you when done" (notification fallback handled in background).
    private func armLongTaskTimers() {
        longTaskTimer?.cancel()
        typingText = "Thinking…"
        longTaskTimer = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.typingText = "Still thinking, almost there…" }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.typingText = "This is taking a while; I will notify you when done" }
        }
    }

    private func ensureExecCard() {
        guard execCardRowId == nil else { return }
        let state = ExecCardState(stages: VSLogic.execStages.map { StageState(name: $0) })
        execCardRowId = state.id
        rows.append(.execCard(state))
    }

    /// On a stage step name: light that stage and mark the previous ones done (P2 item-by-item highlight).
    private func advanceExec(toStage step: String) {
        guard let idx = VSLogic.execIndex(ofStep: step) else { return }
        for i in rows.indices {
            if case .execCard(var st) = rows[i] {
                for j in st.stages.indices {
                    st.stages[j].done = (j < idx)
                    st.stages[j].active = (j == idx)
                }
                rows[i] = .execCard(st)
            }
        }
    }

    private func closeExecCard() {
        longTaskTimer?.cancel()
        typingText = "Thinking…"
        execCardRowId = nil
        // v2.2 fix: when a terminal state arrives, remove residual execCard/typing intermediate bubbles from rows,
        // keeping only "user bubble + final reply" (a clean Doubao-style chat flow, no stacking "Thinking" each turn).
        rows.removeAll {
            if case .execCard = $0 { return true }
            if case .typing = $0 { return true }
            return false
        }
    }

    /// 统一 done 渲染（轮询 route(done) 与 SSE .done 两路共用）。
    /// D0 冻结契约：
    ///   1) reply 存在 → 作为"回答内容"上屏，覆盖正则拆出的『结果：』行（唯一可信渲染源）；
    ///      动作/文件/撤销仍来自 receipt 解析（回退）。
    ///   2) reply 缺失 → receipt 四行有实质内容则按回执卡渲染。
    ///   3) reply 与 receipt 都空 → 诚实"无回答"文案，禁止本地伪造"完成"。
    private func renderDone(_ view: TaskView) {
        let dp = VSLogic.nextDecisionPoint(view)
        guard dp.kind == .receipt else { return }
        var receipt = dp.receipt
        // v2.3 (user request: WeChat-style "Processed in Xs"): record this turn's duration above the bubble.
        receipt.elapsedSec = Date().timeIntervalSince(lastSubmitAt)
        let badges = VSLogic.compressBadges(view)

        // 1) reply 优先：服务端给的回答正文。
        if let reply = view.reply, !reply.isEmpty {
            receipt.result = reply
            rows.append(.receipt(ReceiptRow(receipt: receipt, undo: dp.undo, badges: badges)))
            scrollTick += 1
            // T3 豆包式：朗读回答正文。
            speak(reply)
            return
        }

        // 2) 无 reply：receipt 有动作/文件/结果任一实质内容 → 正常回执卡。
        let hasReceiptContent = !receipt.action.isEmpty || !receipt.files.isEmpty || !receipt.result.isEmpty
        if hasReceiptContent {
            rows.append(.receipt(ReceiptRow(receipt: receipt, undo: dp.undo, badges: badges)))
            scrollTick += 1
            speak(receipt.result)
            return
        }

        // 3) 都空：诚实提示，不伪造完成。
        DiagLogger.shared.log("DONE", "done 但 reply/receipt 均空 → 诚实文案，不伪造完成")
        appendHarness("任务已结束，但暂未返回回答，请稍后重试。", view: view, spoken: true)
    }

    // MARK: - v2.4 attachments

    func addAttachment(_ a: Attachment) {
        pendingAttachments.append(a)
    }

    func removeAttachment(_ id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Compatibility overload: the view layer calls removeAttachment(_:) with an Attachment.
    func removeAttachment(_ a: Attachment) {
        pendingAttachments.removeAll { $0.id == a.id }
    }

    // MARK: - v2.4 multi-session switching

    /// Switch to a session: persist current rows back -> switchTo -> load the new session's rows -> clear transient state.
    func switchSession(_ id: String) {
        guard id != currentSessionID else { return }
        persistCurrentRows()
        SessionStore.shared.switchTo(id: id)
        currentSessionID = id
        loadCurrentRows()
        resetTransientState()
    }

    /// New session: save the current session -> createSession -> load empty rows -> clear transient state.
    func newSession() {
        persistCurrentRows()
        let s = SessionStore.shared.createSession(title: "New Chat")
        currentSessionID = s.id
        loadCurrentRows()
        resetTransientState()
    }

    // MARK: - V6.2 role/domain container sessions

    /// Start a new session inside a container (new in a role / new in a domain).
    func enterContainerSession(kind: ContainerKind, containerID: String) {
        persistCurrentRows()
        let s = SessionStore.shared.createSession(title: "New Chat",
                                                  containerKind: kind,
                                                  containerID: containerID)
        currentSessionID = s.id
        loadCurrentRows()
        resetTransientState()
    }

    /// Create (or reuse a same-named) container and enter its new session.
    func createContainerAndEnter(kind: ContainerKind, name: String) {
        let c = SessionStore.shared.upsertContainer(kind: kind, name: name)
        enterContainerSession(kind: kind, containerID: c.id)
    }

    /// V6.3 talk-then-file: file an existing session into a container (role/domain).
    func classifySession(_ id: String, kind: ContainerKind, containerID: String) {
        SessionStore.shared.setContainer(sessionID: id, kind: kind, containerID: containerID)
    }

    /// Create (or reuse a same-named) container and file the session into it.
    func createContainerAndClassify(_ id: String, kind: ContainerKind, name: String) {
        let c = SessionStore.shared.upsertContainer(kind: kind, name: name)
        classifySession(id, kind: kind, containerID: c.id)
    }

    /// Move back to ungrouped.
    func unclassifySession(_ id: String) {
        SessionStore.shared.clearContainer(sessionID: id)
    }

    /// V6.3 top-bar ownership label: the container name of the current session (none -> Ungrouped).
    var currentContainerLabel: String {
        guard let s = SessionStore.shared.currentSession,
              let cid = s.containerID,
              let c = SessionStore.shared.containers.first(where: { $0.id == cid }) else {
            return "Ungrouped"
        }
        return c.name
    }

    /// V6.3 machine name = the actual connection target:
    /// - online: show whoever you are connected to (self-hosted = server name; cloud = 'VoxSign Cloud', the default host)
    /// - not online (offline/reconnecting/unknown): show 'Offline' (consistent with the red dot and disabled input)
    func refreshMachineLabel() {
        let store = SettingsStore.shared
        let conn = ConnectivityService.shared.state
        switch conn {
        case .online:
            if store.mode == .selfHosted, let cfg = store.activeServerConfig {
                machineLabel = cfg.name.isEmpty ? "Unnamed server" : cfg.name
            } else {
                machineLabel = "VoxSign Cloud"
            }
        case .offline, .reconnecting, .unknown:
            machineLabel = "Offline"
        }
    }

    /// Delete a session: persist current rows first; if the deleted session was current, switch to the first remaining and load it.
    @discardableResult
    func deleteSession(_ id: String) -> Bool {
        persistCurrentRows()
        let ok = SessionStore.shared.deleteSession(id: id)
        guard ok else { return false }
        currentSessionID = SessionStore.shared.currentSessionID
        loadCurrentRows()
        resetTransientState()
        return true
    }

    // MARK: - v2.4 session internals

    /// Persist the current chat rows back to the current session.
    private func persistCurrentRows() {
        guard !currentSessionID.isEmpty else { return }
        SessionStore.shared.saveMessages(Self.rowsToMessages(rows), for: currentSessionID)
    }

    /// Load chat rows from the store for the current currentSessionID.
    private func loadCurrentRows() {
        rows = Self.messagesToRows(SessionStore.shared.loadMessages(for: currentSessionID))
    }

    /// Clear transient state after switching/deleting/creating a session (decision/system bar/attachments/input/running task).
    private func resetTransientState() {
        decision = nil
        systemBar = nil
        pendingAttachments = []
        inputText = ""
        sseTask?.cancel()
        pollTask?.cancel()
        sseTask = nil
        pollTask = nil
        currentTaskId = nil
        currentView = nil
        execCardRowId = nil
        lastSeq = 0   // seq 按任务隔离；切会话清残留基线
        longTaskTimer?.cancel()
        scrollTick += 1
    }

    // MARK: - ChatRow <-> StoredMessage conversion

    /// rows -> persistable messages (typing/execCard are not persisted; receipt rows -> harness text; undo is not persisted).
    static func rowsToMessages(_ rows: [ChatRow]) -> [StoredMessage] {
        rows.compactMap { row -> StoredMessage? in
            switch row {
            case .user(let b):
                return StoredMessage(id: b.id.uuidString, role: "user", text: b.text,
                                     fromVoice: b.fromVoice, voiceSeconds: b.voiceSeconds,
                                     attachments: b.attachments, timestamp: b.timestamp)
            case .harness(let b):
                return StoredMessage(id: b.id.uuidString, role: "harness", text: b.text,
                                     badges: b.badges, attachments: b.attachments,
                                     costTokens: b.costTokens, timestamp: b.timestamp)
            case .receipt(let r):
                return StoredMessage(id: r.id.uuidString, role: "harness", text: r.receipt.result,
                                     badges: r.badges, elapsedSec: r.receipt.elapsedSec)
            case .typing, .execCard:
                return nil
            }
        }
    }

    /// Persisted messages -> rows (user restores bubble with attachments/voice; harness restores badges/tokens/time).
    static func messagesToRows(_ messages: [StoredMessage]) -> [ChatRow] {
        messages.map { m -> ChatRow in
            switch m.role {
            case "user":
                var b = Bubble(text: m.text, fromVoice: m.fromVoice, attachments: m.attachments)
                b.voiceSeconds = m.voiceSeconds
                b.timestamp = m.timestamp
                return .user(b)
            default:
                // harness message (including receipt result text): restore as a normal harness bubble.
                var b = Bubble(text: m.text, badges: m.badges, attachments: m.attachments)
                b.costTokens = m.costTokens
                b.timestamp = m.timestamp
                return .harness(b)
            }
        }
    }
}
