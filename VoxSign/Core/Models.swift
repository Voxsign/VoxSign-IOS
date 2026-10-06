//
//  Models.swift
//  VoxSign
//
//  Core value types shared by the pure logic layer and the network layer.
//  Zero third-party dependencies (Foundation only).
//

import Foundation

/// Response view for GET /v1/tasks/{id} (aligned with INTERACT-v1; missing fields are
/// treated as defaults and must never crash on absent keys).
struct TaskView: Equatable {
    var taskId: String?
    var status: String?          // running/need_ask/need_confirm/done/canceled/interrupted
    var question: String?
    var options: [TaskOption]?
    var receipt: String?         // four-line receipt text
    var attribution: String?
    var reversible: Bool?
    var error: String?
    /// D0 冻结契约（Phase 1）：outcome.reply = 服务端给用户的「回答正文」。
    /// 已在网络层规范化为纯文本（字符串直取 / 对象取 .text）；缺失为 nil。
    /// done 时作为回答内容的**首选渲染源**（替代正则拆『结果：』），receipt 仅作回退。
    var reply: String?

    /// Fault-tolerant initializer: build a view from any dictionary (shared by tests and SSE done events).
    init(taskId: String? = nil,
         status: String? = nil,
         question: String? = nil,
         options: [TaskOption]? = nil,
         receipt: String? = nil,
         attribution: String? = nil,
         reversible: Bool? = nil,
         error: String? = nil,
         reply: String? = nil) {
        self.taskId = taskId
        self.status = status
        self.question = question
        self.options = options
        self.receipt = receipt
        self.attribution = attribution
        self.reversible = reversible
        self.error = error
        self.reply = reply
    }
}

/// need_ask candidate button: {id,label}.
struct TaskOption: Equatable, Codable {
    let id: String
    let label: String
}

/// Parsed result of the four-line receipt (Action / File / Result / Undo).
struct Receipt: Equatable {
    var action: String = ""
    var files: String = ""
    var result: String = ""
    var undo: String = ""
    /// v2.3 (WeChat-style feedback "how long it took"): processing time for this turn in seconds;
    /// the UI shows "Processed in Xs".
    var elapsedSec: Double = 0
}

/// Verdict for the undo button.
struct UndoInfo: Equatable {
    var show: Bool = false
    var backup: String = ""
    var irreversible: Bool = false
}

/// Lightweight badge (kind: state/intent/domain/risk; tone: blue/green/red/amber/gray).
/// v2.4: gains Codable (needed for session persistence); fields and memberwise init are unchanged.
struct Badge: Equatable, Codable {
    let kind: String
    let label: String
    let tone: String
}

/// One decision point per screen.
enum DecisionKind: String, Equatable {
    case confirm     // red confirm bar (answer:"execute")
    case ask         // follow-up candidate buttons (answer:option.id)
    case error       // canceled/interrupted system error bar
    case receipt     // green receipt card
    case running     // rolling exec card
    case idle
}

struct DecisionPoint: Equatable {
    var kind: DecisionKind
    var question: String = ""
    var options: [TaskOption] = []
    var message: String = ""
    var receipt: Receipt = Receipt()
    var undo: UndoInfo = UndoInfo()
}

/// Three meanings of the red interrupt system bar (Applied / Not executed / Actionable).
struct SystemBarInfo: Equatable {
    var title: String = ""
    var active: [String] = []
    var blocked: [String] = []
    var actions: [String] = []
    var closable: Bool = true
}

/// Role (planner/executor/verifier).
struct RoleInfo: Equatable {
    let id: String
    let label: String
    var active: Bool
}

// MARK: - v2.4 attachments

/// Attachment kind: pasted text / URL / image (photo library) / file (Files app).
enum AttachmentKind: String, Codable {
    case text
    case url
    case image
    case file
}

/// A resource attachment submitted to the harness context with a message.
struct Attachment: Identifiable, Codable, Equatable {
    var id: String            // UUID().uuidString
    var kind: AttachmentKind
    var title: String
    var text: String?         // text kind = body; url kind = URL string
    var fileName: String?     // file kind = file name
    var localPath: String?    // image/file kind = local path (for preview)
}

// MARK: - v2.4 multi-session persistence model

/// A persistent message in a session (user bubble / harness bubble / receipt row).
/// typing/execCard intermediate states are not persisted.
struct StoredMessage: Identifiable, Codable, Equatable {
    var id: String
    var role: String          // "user" | "harness"
    var text: String
    var badges: [Badge] = []
    var fromVoice: Bool = false
    var voiceSeconds: Int? = nil
    var attachments: [Attachment] = []
    var costTokens: Int? = nil
    var timestamp: Date = Date()
    var elapsedSec: Double? = nil   // receipt "Processed in Xs"
}

/// A local session (multi-session: hidden by default, usually a single conversation).
struct ChatSession: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var serverBase: String? = nil
    var messages: [StoredMessage] = []
    // V6.2 session ownership: each session hangs on a "role" or "domain" container
    // (nil = ungrouped, backward compatible with old data).
    var containerKind: ContainerKind? = nil
    var containerID: String? = nil
}

// MARK: - V6.2 Role / Domain containers

/// Container kind: role (actor identity) / domain (topic · project · space).
enum ContainerKind: String, Codable {
    case role, domain
}

/// Container (folder): role or domain. Sessions are grouped under a container by containerID;
/// containers can be collapsed and archived.
struct ContainerItem: Identifiable, Codable, Equatable {
    var id: String
    var kind: ContainerKind
    var name: String
    var createdAt: Date = Date()
}

// MARK: - v2.4 top-bar status dot (pure function, shared by view and tests)

/// Status dot tone.
enum DotTone {
    case blue    // online · running/idle
    case red     // offline (unconditional)
    case gray    // reconnecting / unknown
    case orange  // online · waiting for user confirm/select
}

/// Top-bar dot verdict: connection state x harness state -> tone.
enum TopBarDot {
    /// conn: ConnectivityService.ConnectionState; harness: AppModel.HarnessState.
    /// Rules: offline -> .red (unconditional); online: decision -> .orange, busy -> .blue, idle -> .blue;
    /// reconnecting/unknown -> .gray.
    static func tone(conn: ConnectionState, harness: HarnessState) -> DotTone {
        switch conn {
        case .offline:
            return .red
        case .online:
            switch harness {
            case .decision: return .orange
            case .busy, .idle: return .blue
            }
        case .reconnecting, .unknown:
            return .gray
        }
    }
}

// MARK: - Usage caption (pure function, shared by view and tests)

/// Usage caption: when the server returns nil the whole row is hidden; otherwise show "Used n".
/// The server protocol currently never returns a token usage field, so costTokens is always nil;
/// this pure function makes the implicit if-let tolerance explicit as an open-source decoupling point.
enum CostText {
    static func caption(for tokens: Int?) -> String? {
        guard let tokens else { return nil }
        return "Used \(tokens)"
    }
}
