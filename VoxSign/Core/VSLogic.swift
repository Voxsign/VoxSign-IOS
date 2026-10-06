//
//  VSLogic.swift
//  VoxSign
//
//  Pure-logic layer: terminal/decision state machine, receipt four-line parsing, undo-button
//  verdict, lightweight badge compression, one-decision-point routing, role mapping, interrupt
//  system bar, request id, voice trigger phrases, exec-card stage model, auto-naming.
//  No UI / networking dependencies — fully covered by unit tests.
//

import Foundation

enum VSLogic {

    // MARK: - Exec card: seven pipeline stages

    /// Exec card's seven user-visible pipeline stages (aligned with the pipeline's decision /
    /// execution points). The open-source client speaks the English contract.
    static let execStages: [String] = [
        "Intent", "Domain", "Risk", "Confirm Gate", "Execute", "Verify", "Attribution"
    ]

    static let roleLabels: [String: String] = [
        "planner": "Planner",
        "executor": "Executor",
        "verifier": "Verifier"
    ]

    // MARK: - Terminal / decision state vocabulary (aligned with INTERACT-v1)

    /// Terminal states: done/canceled/interrupted (polling stops here).
    static func isTerminal(_ status: String?) -> Bool {
        guard let s = status else { return false }
        return s == "done" || s == "canceled" || s == "interrupted"
    }

    /// Decision points: need_ask/need_confirm (suspended; polling pauses waiting for the user answer).
    static func isDecision(_ status: String?) -> Bool {
        guard let s = status else { return false }
        return s == "need_ask" || s == "need_confirm"
    }

    // MARK: - request_id (M4 idempotency key)

    /// Client-generated; retries of the same task resend the same id so the server dedupes.
    static func genRequestId() -> String {
        "req-" + UUID().uuidString.lowercased()
    }

    // MARK: - D0 契约：outcome.reply 规范化（Phase 1）
    //
    /**
     * 【伪代码逻辑层】（必写：reply 是服务端下发的"回答正文"，客户端唯一可信来源）
     *   wire 形态 Phase1 = 纯文本字符串：  "reply": "今天天气晴"
     *   防御性兼容对象形态：              "reply": {"text": "今天天气晴"}
     *   规则：
     *     - 字符串：非空即直取；
     *     - 字典：取 ["text"] 字符串；
     *     - 其余 / 空串 → nil（上层按"无回答"诚实渲染，禁止伪造完成）。
     *   注意：本函数不做任何"补全/润色/造文案"——服务端没给回答就是没给。
     */
    static func normalizeReply(_ any: Any?) -> String? {
        if let s = any as? String {
            return s.isEmpty ? nil : s
        }
        if let dict = any as? [String: Any],
           let s = dict["text"] as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    // MARK: - 回执四行解析（contract.RenderReceipt 的反向解析）
    //
    /// server 渲染恰好四行：动作/文件/结果/撤销。
    /// 容错：行缺失 / 全半角冒号 / 多余行 / 前后空白 都不炸，按行首标签归位。
    static func parseReceipt(_ text: String?) -> Receipt {
        var out = Receipt()
        guard let text = text else { return out }
        // Match a leading label: Action/File/Result/Undo, followed by a half/full-width colon.
        let pattern = #"^\s*(Action|File|Result|Undo)\s*[:：]\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            let ns = NSRange(raw.startIndex..., in: raw)
            guard let m = regex.firstMatch(in: raw, range: ns) else { continue }
            // NSRange -> Swift Range<String.Index>, then subscript the String.
            guard let labelRange = Range(m.range(at: 1), in: raw),
                  let valueRange = Range(m.range(at: 2), in: raw) else { continue }
            let label = String(raw[labelRange])
            let value = String(raw[valueRange]).trimmingCharacters(in: .whitespaces)
            switch label {
            case "Action": out.action = value
            case "File": out.files = value
            case "Result": out.result = value
            case "Undo": out.undo = value
            default: break
            }
        }
        return out
    }

    // MARK: - Undo-line parsing (receipt line 4 -> undo button)

    /**
     * Logic-layer contract:
     *   show   = (reversible == true) AND undo line is not declared irreversible.
     *   backup = extract the .bak filename from the undo line (tolerant of the VHS_BACKUP_PATH: prefix).
     * Edge cases: empty undo -> show=false, backup="" (irreversible, no button).
     */
    static func extractUndo(_ receipt: Receipt, _ reversible: Bool?) -> UndoInfo {
        let undo = receipt.undo
        let irreversible = undo.range(of: "irreversible|cannot be undone|no rollback",
                                       options: .regularExpression) != nil
        var info = UndoInfo()
        info.irreversible = irreversible
        info.show = (reversible == true) && !irreversible
        // Extract the .bak filename (tolerant of the VHS_BACKUP_PATH: prefix).
        let bakPattern = #"(?:VHS_BACKUP_PATH\s*[:：]\s*)?([^\s,]+\.bak)"#
        if let r = try? NSRegularExpression(pattern: bakPattern),
           let m = r.firstMatch(in: undo, range: NSRange(undo.startIndex..., in: undo)),
           let rr = Range(m.range(at: 1), in: undo) {
            info.backup = String(undo[rr])
        }
        return info
    }

    // MARK: - Intent keywords -> light badge (compressed from the receipt action line)

    private static let intentWords: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: "NOTE|note|jot", options: .caseInsensitive), "Note"),
        (try! NSRegularExpression(pattern: "EDIT|edit|change|delete", options: .caseInsensitive), "Edit"),
        (try! NSRegularExpression(pattern: "QUERY|query|lookup|search", options: .caseInsensitive), "Query"),
        (try! NSRegularExpression(pattern: "COMMIT|commit", options: .caseInsensitive), "Commit"),
        (try! NSRegularExpression(pattern: "DEPLOY|deploy|release", options: .caseInsensitive), "Deploy")
    ]

    static func intentBadge(_ actionText: String?) -> String {
        let text = actionText ?? ""
        for (re, label) in intentWords {
            if re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return label
            }
        }
        return ""
    }

    static func tone(forStatus s: String?) -> String {
        guard let s = s else { return "blue" }
        switch s {
        case "done": return "green"
        case "need_confirm": return "red"
        case "need_ask": return "amber"
        case "canceled", "interrupted": return "gray"
        default: return "blue"
        }
    }

    // MARK: - Lightweight badge compression (intent / domain / risk / state)

    /**
     * Badges are compressed from state/receipt/attribution; internal detail is not amplified.
     *   view = GET /v1/tasks/{id} response (no full Outcome, only receipt/attribution/reversible).
     * Output badges[] = 2~4 small chips:
     *   state  <- direct status mapping (Running / Needs Input / Needs Confirm / Done / Canceled / Interrupted)
     *   intent <- keywords on the receipt Action line (Note / Edit / Query / Commit / Deploy)
     *   domain <- receipt File line compressed: notes.md -> Notes domain; real object path -> Project domain; none -> omitted
     *   risk   <- need_confirm -> High Risk; reversible -> Reversible; done && !reversible -> Irreversible
     * Principle: never show confidence scores / ASR raw text / correction detail — only the sense of control the user needs.
     */
    static func compressBadges(_ view: TaskView) -> [Badge] {
        var badges: [Badge] = []
        let stateMap: [String: String] = [
            "running": "Running", "need_ask": "Needs Input", "need_confirm": "Needs Confirm",
            "done": "Done", "canceled": "Canceled", "interrupted": "Interrupted"
        ]
        if let st = view.status, let label = stateMap[st] {
            badges.append(Badge(kind: "state", label: label, tone: tone(forStatus: st)))
        }
        let r = parseReceipt(view.receipt)
        let it = intentBadge(r.action)
        if !it.isEmpty {
            badges.append(Badge(kind: "intent", label: it, tone: "blue"))
        }
        if r.files.range(of: "notes?\\.md|note", options: .regularExpression) != nil
            || r.action.range(of: "note|NOTE", options: .regularExpression) != nil {
            badges.append(Badge(kind: "domain", label: "Notes", tone: "gray"))
        } else if !r.files.isEmpty && r.files != "—" {
            badges.append(Badge(kind: "domain", label: "Project", tone: "gray"))
        }
        if view.status == "need_confirm" {
            badges.append(Badge(kind: "risk", label: "High Risk", tone: "red"))
        } else if view.reversible == true {
            badges.append(Badge(kind: "risk", label: "Reversible", tone: "green"))
        } else if view.status == "done" && view.reversible != true {
            badges.append(Badge(kind: "risk", label: "Irreversible", tone: "red"))
        }
        return badges
    }

    // MARK: - One decision point per screen

    static func nextDecisionPoint(_ view: TaskView) -> DecisionPoint {
        switch view.status {
        case "need_confirm":
            return DecisionPoint(kind: .confirm,
                                 question: view.question ?? "Manual approval required (irreversible operation)")
        case "need_ask":
            return DecisionPoint(kind: .ask,
                                 question: view.question ?? "What would you like me to do?",
                                 options: view.options ?? [])
        case "canceled", "interrupted":
            let msg = view.error ?? (view.status == "interrupted"
                ? "Task interrupted, please resubmit" : "Task canceled")
            return DecisionPoint(kind: .error, message: msg)
        case "done":
            let r = parseReceipt(view.receipt)
            return DecisionPoint(kind: .receipt,
                                 receipt: r,
                                 undo: extractUndo(r, view.reversible))
        case "running":
            return DecisionPoint(kind: .running)
        default:
            return DecisionPoint(kind: .idle)
        }
    }

    // MARK: - Role mapping

    static func roleForStatus(_ status: String?) -> String {
        guard let s = status else { return "planner" }
        switch s {
        case "need_ask", "need_confirm": return "planner"
        case "done": return "verifier"
        case "running": return "executor"
        default: return "planner"
        }
    }

    // MARK: - Exec card progress by status (independent of the stage event)

    static func execProgress(forStatus status: String?) -> (doneCount: Int, activeIndex: Int) {
        switch status {
        case "need_ask", "need_confirm": return (4, -1)
        case "done": return (execStages.count, -1)
        default: return (0, -1)
        }
    }

    /// stage.step name -> exec-card row index (nil when not found).
    static func execIndex(ofStep step: String) -> Int? {
        execStages.firstIndex(of: step)
    }

    // MARK: - Voice one-turn-one-clear (P1)

    /**
     * Final ASR result replaces the input box wholesale (never concatenated with old text);
     * after send the recognition buffer is cleared and the next turn starts blank.
     */
    static func voiceReplace(previous: String, final: String) -> String { final }

    // MARK: - Interrupt state machine: say "stop" -> red system bar

    /**
     * Input view = current task view (may be running/need_ask/need_confirm/done).
     *   hasEffect = a receipt already exists AND action/files are non-empty (results landed before done).
     *   active   = hasEffect ? ['Applied: <action> (<files>)']
     *                        : ['Applied: no file changes yet']
     *   blocked  = ['Not executed: later stages aborted']
     *   actions  = ['Continue'] + (undo.show ? ['Undo'] : [])   // Undo first
     * Edge: view empty -> active='No task in progress', actions=[].
     * Note: the system bar is only UI; the real stop is AppModel calling POST /v1/tasks/{id}/cancel.
     */
    static func interruptSystemBar(_ view: TaskView?) -> SystemBarInfo {
        guard let view = view else {
            return SystemBarInfo(title: "Stop", active: ["No task in progress"],
                                 blocked: [], actions: [], closable: true)
        }
        // Fully empty view: no status and no receipt.
        if view.status == nil && view.receipt == nil {
            return SystemBarInfo(title: "Stop", active: ["No task in progress"],
                                 blocked: [], actions: [], closable: true)
        }
        let r = parseReceipt(view.receipt)
        let hasEffect = (view.receipt != nil) && (!r.action.isEmpty || !r.files.isEmpty)
        let active: [String]
        if hasEffect {
            let f = r.files.isEmpty || r.files == "—" ? "" : " (\(r.files))"
            active = ["Applied: \(r.action.isEmpty ? "Changes applied" : r.action)\(f)"]
        } else {
            active = ["Applied: no file changes yet"]
        }
        let blocked = ["Not executed: later stages aborted"]
        var actions = ["Continue"]
        let und = extractUndo(r, view.reversible)
        if und.show { actions.insert("Undo", at: 0) }
        return SystemBarInfo(title: "Stop pressed", active: active,
                             blocked: blocked, actions: actions, closable: true)
    }

    // MARK: - Interrupt trigger phrase detection (say "stop")

    /// The user's trimmed, lowercased text exactly matches "stop/halt/...".
    static func isInterruptPhrase(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return ["stop", "halt", "freeze", "hold on", "cut it"].contains(t)
    }

    // MARK: - v2.1 spoken-answer vocabulary (I06 confirm / I17 undo / noise filter / risk tier)

    /// Very short filler words: meaningless hums (um/uh/oh...) are not submitted and produce no bubble.
    /// Note: confirm answers are consumed by AppModel.sendVoice before this check; "yes/ok" at a
    /// decision point is consumed as a spoken answer.
    static func isNoiseWord(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= 1 { return true }
        let noise: Set<String> = ["um", "umm", "uh", "oh", "ohh", "ah", "ok", "okay", "hmm", "hah", "yeah", "yep", "right", "got it", "understood"]
        return noise.contains(s.lowercased())
    }

    /// Affirmative spoken answers (need_confirm scenario).
    static func isAffirmPhrase(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact: Set<String> = ["execute", "confirm", "yes", "ok", "okay", "do it", "proceed", "continue", "approved", "affirmative", "go ahead", "do it now"]
        return exact.contains(s) || s.hasPrefix("execute")
    }

    /// Negative spoken answers (need_confirm scenario).
    static func isNegativePhrase(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact: Set<String> = ["cancel", "reject", "no", "don't", "stop", "never mind", "skip", "hold"]
        return exact.contains(s) || s.hasPrefix("don't")
    }

    /// Undo spoken phrase (I17 voice undo chain): "undo" / "undo that" / "undo the last one".
    static func isUndoPhrase(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "undo" || s.contains("undo")
    }

    /// High-risk action words (I13 risk tier: commit/push/merge/deploy/delete... spoken answers do
    /// not apply; a button confirmation is forced).
    static func isHighRiskAction(_ probe: String) -> Bool {
        let a = probe.lowercased()
        let highRisk: [String] = ["commit", "push", "merge", "deploy", "release", "delete", "clear", "overwrite", "drop", "migrate", "rm"]
        return highRisk.contains { a.contains($0) }
    }

    /// V6.2 auto-naming: take the first 12 characters of the first user message + "…"
    /// (local fallback; upgraded to AI naming once cloud support lands).
    static func autoTitle(from text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "New Chat" }
        let cleaned = t.replacingOccurrences(of: "\n", with: " ")
        let maxLen = 12
        if cleaned.count <= maxLen { return cleaned }
        return String(cleaned.prefix(maxLen)) + "…"
    }
}
