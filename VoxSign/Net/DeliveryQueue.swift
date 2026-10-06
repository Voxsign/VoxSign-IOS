//
//  DeliveryQueue.swift
//  VoxSign
//
//  T1 background capability · delivery queue:
//  On network loss / background / submit failure, persist (text+mode+request_id) to a queue and
//  flush in order once the network recovers. Idempotency is guaranteed by request_id (the server
//  dedupes POST /v1/tasks with the same request_id -> 200 deduped).
//  Zero third-party deps: file persistence (Application Support) + URLSession (reuses APIClient).
//

import Foundation

/// One pending submission in the queue (Codable for persistence).
struct PendingSubmission: Codable, Equatable {
    let requestId: String
    let text: String
    let mode: String       // voice | text
    let createdAt: Date
    var retryCount: Int

    init(requestId: String = UUID().uuidString, text: String, mode: String, createdAt: Date = Date(), retryCount: Int = 0) {
        self.requestId = requestId
        self.text = text
        self.mode = mode
        self.createdAt = createdAt
        self.retryCount = retryCount
    }
}

/// Delivery queue: FIFO + persistence + backoff retry.
/// - Thread safety: all calls happen on the main actor / serialized access (AppModel is @MainActor).
/// - Persistence: Application Support/DeliveryQueue.jsonl; memory state is kept if a write fails.
/// - Cap: maxStored entries (prevents unbounded growth); overflow drops the oldest.
final class DeliveryQueue {
    static let shared = DeliveryQueue()

    /// Storage root directory (injectable in tests). Defaults to Application Support.
    var storageDirectory: URL? {
        didSet { reload() }
    }
    /// Submission closure (injectable in tests; defaults to APIClient.submitTask).
    var submitter: ((PendingSubmission) async throws -> Void)?
    /// Max backoff seconds (exponential 2^n, capped).
    var maxBackoffSeconds: Int = 300
    /// Enqueue cap.
    var maxStored: Int = 100

    /// Current queue (for UI/tests to read).
    private(set) var pending: [PendingSubmission] = []
    /// Time of the last submit failure (for backoff).
    private(set) var lastFailureAt: Date?

    private let queueURL = "DeliveryQueue.jsonl"

    init() {
        submitter = { [weak self] item in
            _ = try await APIClient.shared.submitTask(text: item.text, requestId: item.requestId)
        }
        reload()
    }

    // MARK: - Persistence

    private func queueFile() -> URL? {
        guard let dir = storageDirectory else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            let newDir = support.appendingPathComponent("VoxSign", isDirectory: true)
            migrateLegacyDirectory(from: support.appendingPathComponent("VoiceSign", isDirectory: true), to: newDir)
            try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            return newDir.appendingPathComponent(queueURL)
        }
        return dir.appendingPathComponent(queueURL)
    }

    /// Migrate the legacy "VoiceSign" offline-queue directory to "VoxSign" so in-flight submissions are not lost.
    /// Only moves the whole directory when the old one exists and the new one does not; otherwise does nothing.
    private func migrateLegacyDirectory(from oldDir: URL, to newDir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) else { return }
        try? fm.createDirectory(at: newDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: oldDir, to: newDir)
    }

    private func reload() {
        guard let file = queueFile(), let data = try? Data(contentsOf: file) else { return }
        let lines = data.split(separator: 0x0A).compactMap { line -> PendingSubmission? in
            guard let d = String(data: Data(line), encoding: .utf8)?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(PendingSubmission.self, from: d)
        }
        pending = lines
    }

    private func persist() {
        guard let file = queueFile() else { return }
        let lines = pending.compactMap { item -> Data? in try? JSONEncoder().encode(item) }
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Queue operations

    /// Enqueue (on network loss/failure). Returns whether enqueue succeeded.
    @discardableResult
    func enqueue(_ item: PendingSubmission) -> Bool {
        if pending.count >= maxStored {
            if pending.isEmpty { return false } // cap reached and empty (maxStored=0)
            pending.removeFirst()               // overflow: drop oldest
        }
        pending.append(item)
        persist()
        return true
    }

    /// Whether the queue is empty.
    var isEmpty: Bool { pending.isEmpty }

    /// Number of pending submissions.
    var count: Int { pending.count }

    /// Clear all (after a successful flush).
    func clearAll() {
        pending.removeAll()
        lastFailureAt = nil
        persist()
    }

    // MARK: - Flush

    /// Try to flush everything: submit one by one; stop on first failure (order-preserving + backoff); remove on success.
    /// - Returns: number delivered in this pass.
    @discardableResult
    func flush() async -> Int {
        guard !pending.isEmpty else { return 0 }
        // Backoff: if less than 2^retry seconds since the last failure, wait this whole pass (avoid pointless storms).
        if let failAt = lastFailureAt {
            let first = pending[0]
            let backoff = min(maxBackoffSeconds, 1 << min(first.retryCount, 9))
            if Date().timeIntervalSince(failAt) < Double(backoff) {
                return 0
            }
        }
        var delivered = 0
        var idx = 0
        while idx < pending.count {
            let item = pending[idx]
            do {
                if let submitter = submitter {
                    try await submitter(item)
                }
                pending.remove(at: idx)          // remove on success
                delivered += 1
                lastFailureAt = nil
            } catch {
                pending[idx].retryCount += 1     // failure count +1 (longer backoff next time)
                lastFailureAt = Date()
                persist()
                break                             // order-preserving: stop when the head blocks
            }
        }
        persist()
        return delivered
    }
}
