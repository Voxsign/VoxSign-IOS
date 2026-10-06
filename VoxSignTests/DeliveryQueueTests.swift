//
//  DeliveryQueueTests.swift
//  VoxSignTests
//
//  T1 delivery-queue tests: enqueue / persistence / resend / backoff / idempotency key.
//

import XCTest
@testable import VoxSign

final class DeliveryQueueTests: XCTestCase {

    private var tempDir: URL!
    private var queue: DeliveryQueue!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vhs-dq-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        queue = DeliveryQueue()
        queue.storageDirectory = tempDir
        queue.clearAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testEnqueueAndCount() {
        XCTAssertTrue(queue.isEmpty)
        queue.enqueue(PendingSubmission(text: "look up docs", mode: "voice"))
        XCTAssertEqual(queue.count, 1)
        queue.enqueue(PendingSubmission(text: "tidy the file list", mode: "text"))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.pending.first?.text, "look up docs") // FIFO
    }

    func testPersistenceAcrossReload() {
        queue.enqueue(PendingSubmission(text: "first", mode: "text"))
        queue.enqueue(PendingSubmission(text: "second", mode: "voice"))

        let reloaded = DeliveryQueue()
        reloaded.storageDirectory = tempDir
        XCTAssertEqual(reloaded.count, 2, "persisted entries should survive a reload")
        XCTAssertEqual(reloaded.pending.map(\.text), ["first", "second"])
    }

    func testFlushSuccessRemovesAll() async {
        var submitted: [String] = []
        queue.submitter = { item in submitted.append(item.text) }
        queue.enqueue(PendingSubmission(text: "a", mode: "text"))
        queue.enqueue(PendingSubmission(text: "b", mode: "voice"))

        let n = await queue.flush()
        XCTAssertEqual(n, 2)
        XCTAssertEqual(submitted, ["a", "b"])
        XCTAssertTrue(queue.isEmpty)
    }

    func testFlushFailureKeepsOrderAndBackoff() async {
        var calls = 0
        queue.submitter = { _ in
            calls += 1
            throw APIError.transport("network unreachable")
        }
        queue.enqueue(PendingSubmission(text: "a", mode: "text"))
        queue.enqueue(PendingSubmission(text: "b", mode: "voice"))

        let n = await queue.flush()
        XCTAssertEqual(n, 0, "a failure on the first item should stop the whole round (order-preserving)")
        XCTAssertEqual(queue.count, 2, "failed entries are kept")
        XCTAssertEqual(queue.pending[0].retryCount, 1, "failure count +1")

        // Backoff: an immediate flush right after a failure should return 0 (no storm)
        let again = await queue.flush()
        XCTAssertEqual(again, 0, "no retry within the backoff window")
    }

    func testFlushRecoversAfterBackoff() async {
        var calls = 0
        queue.maxBackoffSeconds = 0 // disable backoff so we can retry immediately
        queue.submitter = { _ in
            calls += 1
            if calls == 1 { throw APIError.transport("transient failure") }
        }
        queue.enqueue(PendingSubmission(text: "a", mode: "text"))
        _ = await queue.flush()
        XCTAssertEqual(queue.count, 1)

        let n = await queue.flush()
        XCTAssertEqual(n, 1, "the second flush should resend successfully")
        XCTAssertTrue(queue.isEmpty)
    }

    func testMaxStoredDropsOldest() {
        queue.maxStored = 3
        for i in 0..<5 {
            queue.enqueue(PendingSubmission(text: "t\(i)", mode: "text"))
        }
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.pending.map(\.text), ["t2", "t3", "t4"], "over capacity drops the oldest")
    }
}
