//
//  SSEParser.swift
//  VoxSign
//
//  Server-Sent Events stream parser (pure logic, no networking) aligned with the SSE-v1
//  event-stream contract:
//  - Standard SSE framing: events are separated by a blank line; `event:` gives the type
//    (defaults to message); multi-line `data:` is joined with \n.
//  - data always carries `seq` (monotonic, unique within a task, starting at 1); missing
//    fields default safely and must never crash.
//  - Reconnect: the client keeps lastSeq and reconnects with `?after=<lastSeq>`; the server
//    replays seq > after.
//

import Foundation

/// Normalized SSE event type.
enum SSEEvent: Equatable {
    case stage(seq: Int, role: String?, phase: String?, step: String?)
    case ask(seq: Int, question: String, options: [TaskOption])
    case confirm(seq: Int, question: String)
    case done(seq: Int, receipt: String?, attribution: String?, reversible: Bool?, role: String?, reply: String?)
    case failed(seq: Int, error: String?)
    case interrupt(seq: Int, applied: [String], notApplied: [String], canRollback: Bool)
    case canceled(seq: Int)
    case unknown(type: String, seq: Int?)

    /// Event seq (unknown may omit it).
    var seq: Int? {
        switch self {
        case .stage(let s, _, _, _), .ask(let s, _, _), .confirm(let s, _),
             .done(let s, _, _, _, _, _), .failed(let s, _), .interrupt(let s, _, _, _),
             .canceled(let s):
            return s
        case .unknown(_, let s):
            return s
        }
    }

    /// Whether this is a terminal event (the connection should close): done/failed/canceled.
    var isTerminal: Bool {
        switch self {
        case .done, .failed, .canceled: return true
        default: return false
        }
    }
}

/// Decode a raw data JSON dictionary into a strongly-typed SSEEvent by event type.
/// Consumers default missing data fields; decoding must never crash on absent keys.
enum SSEDecoder {

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }()

    static func decode(type rawType: String, data raw: String) -> SSEEvent {
        let type = rawType.isEmpty ? "message" : rawType
        // data may be a multi-line joined JSON string.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unknown(type: type, seq: nil)
        }
        let seq = (dict["seq"] as? NSNumber)?.intValue ?? (dict["seq"] as? Int) ?? -1
        switch type {
        case "stage":
            return .stage(seq: seq,
                          role: dict["role"] as? String,
                          phase: dict["phase"] as? String,
                          step: dict["step"] as? String)
        case "need_ask":
            let options = decodeOptions(dict["options"])
            return .ask(seq: seq,
                        question: dict["question"] as? String ?? "",
                        options: options)
        case "need_confirm":
            return .confirm(seq: seq, question: dict["question"] as? String ?? "")
        case "done":
            return .done(seq: seq,
                         receipt: dict["receipt"] as? String,
                         attribution: dict["attribution"] as? String,
                         reversible: dict["reversible"] as? Bool,
                         role: dict["role"] as? String,
                         reply: VSLogic.normalizeReply(dict["reply"]))
        case "failed":
            return .failed(seq: seq, error: dict["error"] as? String)
        case "interrupt":
            return .interrupt(seq: seq,
                             applied: toStringArray(dict["applied"]),
                             notApplied: toStringArray(dict["notApplied"]),
                             canRollback: (dict["canRollback"] as? Bool) ?? false)
        case "canceled":
            return .canceled(seq: seq)
        default:
            return .unknown(type: type, seq: seq < 0 ? nil : seq)
        }
    }

    private static func decodeOptions(_ any: Any?) -> [TaskOption] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let id = o["id"] as? String, let label = o["label"] as? String else { return nil }
            return TaskOption(id: id, label: label)
        }
    }

    private static func toStringArray(_ any: Any?) -> [String] {
        guard let arr = any as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }
}

/// Streaming SSE frame parser: feed arbitrary byte chunks, emit fully-formed events.
/**
 * [Logic layer pseudocode]
 *   feed(chunk):
 *     buffer += chunk
 *     while buffer contains "\n\n" (or "\r\n\r\n"):
 *        take one block (up to the first blank line)
 *        parse the block's multiple lines:
 *          event: <type>        -> eventType (default "message")
 *          data:  <line>        -> dataLines += line (multi-line data joined with \n)
 *        event = SSEDecoder.decode(eventType, dataLines.joined("\n"))
 *        lastSeq = max(lastSeq, event.seq)
 *        yield(event)
 *   Reconnect: rebuild URL?after=<lastSeq> from lastSeq; the server replays seq > after,
 *   with no duplicates and no loss.
 *   Edge cases: a partial event (no trailing blank line at buffer end) stays buffered until the
 *   next chunk; JSON decode failure -> unknown, never crash.
 */
final class SSEParser {
    private var buffer = ""
    private(set) var lastSeq: Int = 0

    init() {}

    /// Feed a chunk of text; return all events completed within this chunk.
    func feed(_ text: String) -> [SSEEvent] {
        buffer += text
        var events: [SSEEvent] = []
        // Repeatedly cut out blocks ending at a blank line (\n\n or \r\n\r\n).
        while let range = buffer.range(of: "\n\n") ?? buffer.range(of: "\r\n\r\n") {
            let block = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let ev = parseBlock(block) {
                if let s = ev.seq, s > lastSeq { lastSeq = s }
                events.append(ev)
            }
        }
        return events
    }

    /// Parse one complete block into an event; returns nil for an empty block.
    private func parseBlock(_ block: String) -> SSEEvent? {
        var eventType = ""
        var dataLines: [String] = []
        // Tolerate \n and \r\n line endings.
        for line in block.components(separatedBy: "\n") {
            let trimmedCR = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if trimmedCR.hasPrefix("event:") {
                eventType = String(trimmedCR.dropFirst("event:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmedCR.hasPrefix("data:") {
                var d = String(trimmedCR.dropFirst("data:".count))
                // SSE spec: strip a single leading space after the colon.
                if d.hasPrefix(" ") { d.removeFirst() }
                dataLines.append(d)
            }
            // Ignore other lines (id:/retry:/comments) — the contract only uses event/data.
        }
        if dataLines.isEmpty && eventType.isEmpty { return nil }
        return SSEDecoder.decode(type: eventType, data: dataLines.joined(separator: "\n"))
    }

    /// Reconnect URL: append ?after=<lastSeq> to the event path (the contract also allows the
    /// standard Last-Event-ID header).
    static func reconnectURL(base: URL, after lastSeq: Int) -> URL {
        if var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            var items = comps.queryItems ?? []
            items = items.filter { $0.name != "after" }
            items.append(URLQueryItem(name: "after", value: String(lastSeq)))
            comps.queryItems = items
            return comps.url ?? base
        }
        return base
    }
}
