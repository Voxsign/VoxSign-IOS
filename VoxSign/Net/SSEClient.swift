//
//  SSEClient.swift
//  VoxSign
//
//  SSE event-stream client (GET /v1/tasks/{id}/events, Bearer auth).
//  Reads the stream line by line via URLSession.bytes(for:), feeds SSEParser, and reconnects with
//  ?after=lastSeq on drop. The connection stays open until a terminal task state
//  (done/failed/canceled/interrupted) closes it.
//

import Foundation

/// Turns the SSE byte stream into an AsyncThrowingStream<SSEEvent>.
final class SSEClient {
    static let shared = SSEClient()
    var settings: SettingsStore = .shared

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        // Fix the root cause of the freeze (T2): with waitsForConnectivity=true, an unreachable
        // network makes URLSession wait forever to establish — when the phone can't reach the
        // server the UI "freezes". We use an explicit racing timeout (connectTimeout) instead:
        // if we can't connect within 10s we throw and let the upper layer decide to reconnect.
        cfg.waitsForConnectivity = false
        // 60s is only the idle timeout (no bytes on the stream for a while); SSE keepalive is well under it.
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg)
    }()

    /// Max wait to establish a connection (s): a racing timeout for the TCP/HTTP handshake; on timeout treat as connection failure.
    /// The upper layer (AppModel.openSSE) reconnects with backoff, so nothing hangs forever.
    private let connectTimeout: TimeInterval = 10

    /// Subscribe to a task's event stream.
    /// - Parameter taskId: task id
    /// - Parameter after: lastSeq on reconnect (0 on first connect = from the first event)
    /// - Returns: an event AsyncThrowingStream; it ends naturally after a terminal event.
    func events(taskId: String, after: Int = 0) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }
            let basePath = "/v1/tasks/\(taskId)/events"
            guard let baseURL = self.settings.url(basePath) else {
                continuation.finish(throwing: APIError.transport("Invalid server address"))
                return
            }
            let url = after > 0 ? SSEParser.reconnectURL(base: baseURL, after: after) : baseURL
            var req = URLRequest(url: url)
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            // D0 贯穿 trace：SSE 流同样携带 X-Request-Id（每次连接一个新 UUID）。
            req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
            if !self.settings.token.isEmpty {
                req.setValue("Bearer \(self.settings.token)", forHTTPHeaderField: "Authorization")
            }
            // SSE spec: reconnect can also use the Last-Event-ID header (here we use ?after=query, both contract-compatible).

            let parser = SSEParser()
            let task = Task {
                do {
                    // T2 racing connect timeout: URLSession's timeoutIntervalForRequest only covers
                    // idle timeout, not "can't connect" — we add a connectTimeout sentinel task via
                    // withThrowingTaskGroup and whichever finishes/fails first wins.
                    let (bytes, resp): (URLSession.AsyncBytes, URLResponse) = try await withThrowingTaskGroup(of: (URLSession.AsyncBytes, URLResponse).self) { group in
                        group.addTask {
                            let (b, r) = try await self.session.bytes(for: req)
                            return (b, r)
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(self.connectTimeout * 1_000_000_000))
                            throw APIError.transport("SSE connect timeout (\(Int(self.connectTimeout))s; service unreachable?)")
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                    guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        continuation.finish(throwing: APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                                                   "SSE connection failed"))
                        return
                    }
                    for try await line in bytes.lines {
                        // bytes.lines yields single lines; SSE events are separated by blank lines,
                        // so we feed each line (with trailing newline) back to the parser to frame correctly.
                        let events = parser.feed(line + "\n")
                        for ev in events {
                            continuation.yield(ev)
                            if ev.isTerminal {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
