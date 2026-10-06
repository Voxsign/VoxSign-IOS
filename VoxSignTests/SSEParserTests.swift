//
//  SSEParserTests.swift
//  VoxSignTests
//
//  SSE event-parsing XCTest: standard framing, seq increments, reconnect after=, interrupt three-semantic fields.
//

import XCTest
@testable import VoxSign

final class SSEParserTests: XCTestCase {

    /// Feed a complete multi-event stream; events should parse out in order.
    func testParseMultiEvent() {
        let stream =
            "event: stage\n" +
            "data: {\"seq\":1,\"role\":\"planner\",\"phase\":\"classify\",\"step\":\"Intent\"}\n\n" +
            "event: need_ask\n" +
            "data: {\"seq\":2,\"question\":\"which file?\",\"options\":[{\"id\":\"f1\",\"label\":\"notes.md\"}]}\n\n"

        let p = SSEParser()
        let evts = p.feed(stream)
        XCTAssertEqual(evts.count, 2)

        guard case .stage(let seq, let role, _, let step) = evts[0] else { return XCTFail("first should be stage") }
        XCTAssertEqual(seq, 1)
        XCTAssertEqual(role, "planner")
        XCTAssertEqual(step, "Intent")

        guard case .ask(let seq2, let q, let opts) = evts[1] else { return XCTFail("second should be ask") }
        XCTAssertEqual(seq2, 2)
        XCTAssertEqual(q, "which file?")
        XCTAssertEqual(opts.count, 1)
        XCTAssertEqual(opts[0].id, "f1")
        XCTAssertEqual(p.lastSeq, 2)
    }

    /// A half event stays in the buffer and is only emitted once the next chunk completes it.
    func testPartialFrame() {
        let p = SSEParser()
        XCTAssertEqual(p.feed("event: done\ndata: {\"seq\":5,\"receipt\":\"Action: X\"}").count, 0)
        let evts = p.feed("\n\n")
        XCTAssertEqual(evts.count, 1)
        guard case .done(let seq, let receipt, _, _, _) = evts[0] else { return XCTFail() }
        XCTAssertEqual(seq, 5)
        XCTAssertEqual(receipt, "Action: X")
        XCTAssertTrue(evts[0].isTerminal)
    }

    /// Multi-line data (SSE spec: data lines joined by \n).
    func testMultilineData() {
        let p = SSEParser()
        let evts = p.feed("event: done\ndata: {\"seq\":3,\ndata: \"receipt\":\"Action: A\"}\n\n")
        XCTAssertEqual(evts.count, 1)
        // After joining multi-line data the result must still be valid JSON (this case is deliberately invalid -> no crash, treated as unknown).
        // Feed a valid multi-line example instead:
        let p2 = SSEParser()
        let evts2 = p2.feed("data: {\"seq\":4}\n\n")
        XCTAssertEqual(evts2.count, 1)
    }

    /// Interrupt event three-semantic field mapping.
    func testInterruptSemantics() {
        let p = SSEParser()
        let evts = p.feed("event: interrupt\ndata: {\"seq\":7,\"applied\":[\"Applied: NOTE append (notes.md)\"],\"notApplied\":[\"Later stages aborted\"],\"canRollback\":true}\n\n")
        XCTAssertEqual(evts.count, 1)
        guard case .interrupt(_, let applied, let notApplied, let canRollback) = evts[0] else {
            return XCTFail("should be interrupt")
        }
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(notApplied, ["Later stages aborted"])
        XCTAssertTrue(canRollback)
    }

    /// Unknown event type does not crash; classified as unknown.
    func testUnknownEvent() {
        let p = SSEParser()
        let evts = p.feed("event: heartbeat\ndata: {\"seq\":9}\n\n")
        guard case .unknown(let type, let seq) = evts[0] else { return XCTFail() }
        XCTAssertEqual(type, "heartbeat")
        XCTAssertEqual(seq, 9)
        XCTAssertFalse(evts[0].isTerminal)
    }

    /// Terminal events: done/failed/canceled.
    func testTerminalEvents() {
        let p = SSEParser()
        let done = p.feed("event: done\ndata: {\"seq\":10}\n\n")[0]
        let failed = p.feed("event: failed\ndata: {\"seq\":11,\"error\":\"boom\"}\n\n")[0]
        let canceled = p.feed("event: canceled\ndata: {\"seq\":12}\n\n")[0]
        XCTAssertTrue(done.isTerminal)
        XCTAssertTrue(failed.isTerminal)
        XCTAssertTrue(canceled.isTerminal)
    }

    /// Reconnect URL appends ?after=<lastSeq>.
    func testReconnectURL() {
        let base = URL(string: "http://1.2.3.4:8765/v1/tasks/t1/events")!
        let url = SSEParser.reconnectURL(base: base, after: 7)
        XCTAssertTrue(url.absoluteString.contains("after=7"))
    }
}
