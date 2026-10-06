//
//  VSLogicTests.swift
//  VoxSignTests
//
//  Pure-logic XCTest (1:1 coverage of web/test.js cases + SSE/reconnect additions).
//

import XCTest
@testable import VoxSign

final class VSLogicTests: XCTestCase {

    // MARK: - 1. Terminal / decision-point state machine

    func testTerminal() {
        XCTAssertTrue(VSLogic.isTerminal("done"))
        XCTAssertTrue(VSLogic.isTerminal("canceled"))
        XCTAssertTrue(VSLogic.isTerminal("interrupted"))
        XCTAssertFalse(VSLogic.isTerminal("running"))
        XCTAssertFalse(VSLogic.isTerminal("need_ask"))
        XCTAssertTrue(VSLogic.isDecision("need_confirm"))
        XCTAssertFalse(VSLogic.isDecision("done"))
    }

    // MARK: - 2. Receipt four-line parsing

    func testParseReceipt() {
        let text = "Action: NOTE append a line\nFile: notes.md\nResult: OK appended\nUndo: restore from backup notes.md.20261002T1530.bak"
        let r = VSLogic.parseReceipt(text)
        XCTAssertEqual(r.action, "NOTE append a line")
        XCTAssertEqual(r.files, "notes.md")
        XCTAssertEqual(r.result, "OK appended")
        XCTAssertEqual(r.undo, "restore from backup notes.md.20261002T1530.bak")

        let empty = VSLogic.parseReceipt("")
        XCTAssertEqual(empty, Receipt())

        // Half-width colon + missing lines
        let r3 = VSLogic.parseReceipt("Action:COMMIT commit\nUndo: irreversible (cannot be undone, manually confirmed)")
        XCTAssertEqual(r3.result, "")
        XCTAssertEqual(r3.undo, "irreversible (cannot be undone, manually confirmed)")
    }

    // MARK: - 3. Undo-button verdict

    func testExtractUndo() {
        let r = VSLogic.parseReceipt("Action: NOTE append a line\nFile: notes.md\nResult: OK\nUndo: restore from backup notes.md.20261002T1530.bak")
        let u = VSLogic.extractUndo(r, true)
        XCTAssertTrue(u.show)
        XCTAssertEqual(u.backup, "notes.md.20261002T1530.bak")
        XCTAssertFalse(u.irreversible)

        // Undo line declares irreversible -> no button
        let c = VSLogic.parseReceipt("Action: COMMIT\nUndo: irreversible (cannot be undone, manually confirmed)")
        XCTAssertFalse(VSLogic.extractUndo(c, true).show)
        // Server did not mark reversible -> no button
        XCTAssertFalse(VSLogic.extractUndo(r, false).show)
        // VHS_BACKUP_PATH prefix tolerance
        let b = VSLogic.extractUndo(VSLogic.parseReceipt("Undo: VHS_BACKUP_PATH: notes.md.20261002T.bak"), true)
        XCTAssertEqual(b.backup, "notes.md.20261002T.bak")
    }

    // MARK: - 4. Light badge compression

    func testBadges() {
        let receipt = "Action: NOTE append a line\nFile: notes.md\nResult: OK\nUndo: restore from backup x.bak"
        let bs = VSLogic.compressBadges(TaskView(status: "running", receipt: receipt, reversible: true))
        XCTAssertTrue(bs.contains(where: { $0.label == "Running" && $0.tone == "blue" }))
        XCTAssertTrue(bs.contains(where: { $0.label == "Note" && $0.kind == "intent" }))
        XCTAssertTrue(bs.contains(where: { $0.label == "Notes" }))
        XCTAssertTrue(bs.contains(where: { $0.label == "Reversible" && $0.tone == "green" }))

        let b2 = VSLogic.compressBadges(TaskView(status: "need_confirm", question: "manual approval"))
        XCTAssertTrue(b2.contains(where: { $0.label == "High Risk" && $0.tone == "red" }))

        let b3 = VSLogic.compressBadges(TaskView(status: "done", receipt: "Action: COMMIT commit", reversible: false))
        XCTAssertTrue(b3.contains(where: { $0.label == "Irreversible" && $0.tone == "red" }))
    }

    // MARK: - 5. One-decision-point-per-screen routing

    func testDecisionRoute() {
        XCTAssertEqual(VSLogic.nextDecisionPoint(TaskView(status: "need_confirm", question: "manual approval")).kind, .confirm)
        let ask = VSLogic.nextDecisionPoint(TaskView(status: "need_ask", question: "which?",
            options: [TaskOption(id: "f1", label: "notes.md"), TaskOption(id: "f2", label: "main.go")]))
        XCTAssertEqual(ask.kind, .ask)
        XCTAssertEqual(ask.options.count, 2)
        XCTAssertEqual(VSLogic.nextDecisionPoint(TaskView(status: "done",
            receipt: "Action: NOTE\nFile: notes.md\nResult: OK\nUndo: x.bak", reversible: true)).kind, .receipt)
        XCTAssertEqual(VSLogic.nextDecisionPoint(TaskView(status: "running")).kind, .running)
        XCTAssertEqual(VSLogic.nextDecisionPoint(TaskView(status: "canceled", error: "canceled")).kind, .error)
        XCTAssertEqual(VSLogic.nextDecisionPoint(TaskView(status: "interrupted")).kind, .error)
    }

    // MARK: - 6. Role mapping

    func testRole() {
        XCTAssertEqual(VSLogic.roleForStatus("need_ask"), "planner")
        XCTAssertEqual(VSLogic.roleForStatus("need_confirm"), "planner")
        XCTAssertEqual(VSLogic.roleForStatus("running"), "executor")
        XCTAssertEqual(VSLogic.roleForStatus("done"), "verifier")
        XCTAssertEqual(VSLogic.roleLabels["verifier"], "Verifier")
    }

    // MARK: - 7. Interrupt state machine

    func testInterruptBar() {
        let bar = VSLogic.interruptSystemBar(TaskView(status: "running"))
        XCTAssertTrue(bar.active[0].contains("no file changes yet"))
        XCTAssertEqual(bar.actions, ["Continue"])

        let receipt = "Action: NOTE append a line\nFile: notes.md\nResult: OK\nUndo: x.bak"
        let bar2 = VSLogic.interruptSystemBar(TaskView(status: "done", receipt: receipt, reversible: true))
        XCTAssertTrue(bar2.active[0].contains("NOTE append a line"))
        XCTAssertTrue(bar2.actions.contains("Undo"))
        XCTAssertTrue(bar2.actions.contains("Continue"))

        XCTAssertEqual(VSLogic.interruptSystemBar(TaskView()).actions, [])
    }

    // MARK: - 8. request_id / exec stages / interrupt phrases

    func testRequestId() {
        XCTAssertEqual(VSLogic.genRequestId().prefix(4), "req-")
        XCTAssertNotEqual(VSLogic.genRequestId(), VSLogic.genRequestId())
        XCTAssertGreaterThanOrEqual(VSLogic.execStages.count, 6)
        XCTAssertTrue(VSLogic.isInterruptPhrase("stop"))
        XCTAssertTrue(VSLogic.isInterruptPhrase(" halt "))
        XCTAssertFalse(VSLogic.isInterruptPhrase("jot this down"))
    }

    // MARK: - 9. V6.2 auto-naming

    func testAutoTitle() {
        // Empty -> fallback "New Chat"
        XCTAssertEqual(VSLogic.autoTitle(from: "   "), "New Chat")
        // Short text as-is
        XCTAssertEqual(VSLogic.autoTitle(from: "short note"), "short note")
        // Long text truncated to 12 chars + ellipsis
        XCTAssertEqual(VSLogic.autoTitle(from: "a much longer title here"), "a much longe…")
        // Newline collapsed to space
        XCTAssertEqual(VSLogic.autoTitle(from: "first line\nsecond line third"), "first line s…")
    }
}
