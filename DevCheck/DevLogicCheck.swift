//
//  DevLogicCheck.swift — macOS command-line assertions (bypasses the simulator sandbox and runs
//  the same pure logic directly on the host).
//  Run: swiftc -o /tmp/vscheck DevLogicCheck.swift ../VoxSign/Core/Models.swift ../VoxSign/Core/VSLogic.swift ../VoxSign/Core/SSEParser.swift && /tmp/vscheck
//  Note: this file is not in any Xcode target; it only runs logic assertions on the host during development.
//

import Foundation

var pass = 0, fail = 0
func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    if a == b { pass += 1; print("  ✓ \(name)") }
    else { fail += 1; print("  ✗ \(name)\n      expected: \(b)\n      actual:   \(a)") }
}
func ok(_ c: Bool, _ name: String) { eq(c, true, name) }

print("== 1. Terminal / decision point ==")
eq(VSLogic.isTerminal("done"), true, "done terminal")
eq(VSLogic.isTerminal("canceled"), true, "canceled terminal")
eq(VSLogic.isTerminal("interrupted"), true, "interrupted terminal")
eq(VSLogic.isTerminal("running"), false, "running not terminal")
eq(VSLogic.isDecision("need_confirm"), true, "need_confirm decision")
eq(VSLogic.isDecision("done"), false, "done not a decision")

print("== 2. Receipt four lines ==")
let rec = "Action: NOTE append a line\nFile: notes.md\nResult: OK appended\nUndo: restore from backup notes.md.20261002T1530.bak"
let r = VSLogic.parseReceipt(rec)
eq(r.action, "NOTE append a line", "action line")
eq(r.files, "notes.md", "file line")
eq(r.result, "OK appended", "result line")
eq(r.undo, "restore from backup notes.md.20261002T1530.bak", "undo line")
eq(VSLogic.parseReceipt(""), Receipt(), "empty receipt does not crash")
eq(VSLogic.parseReceipt("Action:COMMIT\nUndo: irreversible (cannot be undone, manually confirmed)").undo,
   "irreversible (cannot be undone, manually confirmed)", "half-width colon")

print("== 3. Undo button ==")
let u = VSLogic.extractUndo(r, true)
eq(u.show, true, "reversible + .bak present -> show")
eq(u.backup, "notes.md.20261002T1530.bak", "backup name extracted")
eq(u.irreversible, false, "not irreversible")
eq(VSLogic.extractUndo(VSLogic.parseReceipt("Action: COMMIT\nUndo: irreversible"), true).show, false, "declared irreversible -> no button")
eq(VSLogic.extractUndo(r, false).show, false, "reversible=false -> no button")
eq(VSLogic.extractUndo(VSLogic.parseReceipt("Undo: VHS_BACKUP_PATH: notes.md.20261002T.bak"), true).backup,
   "notes.md.20261002T.bak", "VHS_BACKUP_PATH prefix")

print("== 4. Light badges ==")
let bs = VSLogic.compressBadges(TaskView(status: "running", receipt: rec, reversible: true))
ok(bs.contains { $0.label == "Running" && $0.tone == "blue" }, "running -> Running")
ok(bs.contains { $0.label == "Note" && $0.kind == "intent" }, "NOTE -> Note")
ok(bs.contains { $0.label == "Notes" }, "notes.md -> Notes domain")
ok(bs.contains { $0.label == "Reversible" && $0.tone == "green" }, "reversible -> Reversible")
ok(VSLogic.compressBadges(TaskView(status: "need_confirm", question: "x")).contains { $0.label == "High Risk" },
   "need_confirm -> High Risk")
ok(VSLogic.compressBadges(TaskView(status: "done", receipt: "Action: COMMIT", reversible: false)).contains { $0.label == "Irreversible" },
   "done irreversible -> Irreversible")

print("== 5. Decision-point routing ==")
eq(VSLogic.nextDecisionPoint(TaskView(status: "need_confirm", question: "approve?")).kind, .confirm, "confirm")
let ask = VSLogic.nextDecisionPoint(TaskView(status: "need_ask", question: "which one",
    options: [TaskOption(id: "f1", label: "a"), TaskOption(id: "f2", label: "b")]))
eq(ask.kind, .ask, "ask")
eq(ask.options.count, 2, "option count")
eq(VSLogic.nextDecisionPoint(TaskView(status: "done", receipt: rec, reversible: true)).kind, .receipt, "receipt")
eq(VSLogic.nextDecisionPoint(TaskView(status: "running")).kind, .running, "running")
eq(VSLogic.nextDecisionPoint(TaskView(status: "canceled", error: "x")).kind, .error, "error")
eq(VSLogic.nextDecisionPoint(TaskView(status: "interrupted")).kind, .error, "interrupted error")

print("== 6. Role ==")
eq(VSLogic.roleForStatus("need_ask"), "planner", "need_ask -> planner")
eq(VSLogic.roleForStatus("running"), "executor", "running -> executor")
eq(VSLogic.roleForStatus("done"), "verifier", "done -> verifier")

print("== 7. Interrupt ==")
let bar1 = VSLogic.interruptSystemBar(TaskView(status: "running"))
ok(bar1.active[0].contains("no file changes yet"), "running -> no changes yet")
eq(bar1.actions, ["Continue"], "running actions")
let bar2 = VSLogic.interruptSystemBar(TaskView(status: "done", receipt: rec, reversible: true))
ok(bar2.active[0].contains("NOTE append a line"), "done -> list action")
ok(bar2.actions.contains("Undo") && bar2.actions.contains("Continue"), "reversible -> Undo + Continue")
eq(VSLogic.interruptSystemBar(TaskView()).actions, [], "empty -> no actions")

print("== 8. request_id / interrupt phrases ==")
ok(VSLogic.genRequestId().hasPrefix("req-"), "req prefix")
ok(VSLogic.genRequestId() != VSLogic.genRequestId(), "unique")
ok(VSLogic.isInterruptPhrase("stop"), "stop")
ok(VSLogic.isInterruptPhrase(" halt "), "halt")
ok(!VSLogic.isInterruptPhrase("jot this down"), "not an interrupt phrase")

print("== 9. SSE parsing ==")
let stream =
    "event: stage\ndata: {\"seq\":1,\"role\":\"planner\",\"step\":\"Intent\"}\n\n" +
    "event: need_ask\ndata: {\"seq\":2,\"question\":\"which?\",\"options\":[{\"id\":\"f1\",\"label\":\"x\"}]}\n\n"
let p = SSEParser()
let evs = p.feed(stream)
eq(evs.count, 2, "two events")
if case .stage(let s, let role, _, let step) = evs[0] {
    eq(s, 1, "stage seq"); eq(role, "planner", "stage role"); eq(step, "Intent", "stage step")
} else { ok(false, "stage type") }
if case .ask(let s2, let q, let opts) = evs[1] {
    eq(s2, 2, "ask seq"); eq(q, "which?", "ask question"); eq(opts.count, 1, "ask options")
} else { ok(false, "ask type") }
eq(p.lastSeq, 2, "lastSeq=2")

// Half frame
let p2 = SSEParser()
eq(p2.feed("event: done\ndata: {\"seq\":5,\"receipt\":\"Action: X\"}").count, 0, "half frame -> no event")
let doneEvts = p2.feed("\n\n")
eq(doneEvts.count, 1, "emitted after completion")
if case .done(let s3, let receipt, _, _, _) = doneEvts[0] {
    eq(s3, 5, "done seq"); eq(receipt, "Action: X", "done receipt"); ok(doneEvts[0].isTerminal, "done terminal")
} else { ok(false, "done type") }

// Interrupt three semantics
let p3 = SSEParser()
let intEvts = p3.feed("event: interrupt\ndata: {\"seq\":7,\"applied\":[\"Applied: NOTE (notes.md)\"],\"notApplied\":[\"Later stages aborted\"],\"canRollback\":true}\n\n")
if case .interrupt(_, let applied, let notApplied, let rb) = intEvts[0] {
    eq(applied.count, 1, "applied"); eq(notApplied, ["Later stages aborted"], "notApplied"); eq(rb, true, "canRollback")
} else { ok(false, "interrupt type") }

// Reconnect URL
let url = SSEParser.reconnectURL(base: URL(string: "http://h/v1/tasks/t/events")!, after: 7)
ok(url.absoluteString.contains("after=7"), "reconnect after=7")

print("== 10. M7 quick-usable: exec-card highlight / one-turn-one-clear voice / need_ask decision ==")
// P2 exec-card stage index
eq(VSLogic.execIndex(ofStep: "Intent"), 0, "stage Intent -> 0")
eq(VSLogic.execIndex(ofStep: "Confirm Gate"), 3, "stage Confirm Gate -> 3")
eq(VSLogic.execIndex(ofStep: "nope"), nil as Int?, "unknown stage -> nil")
// P2 exec card advances by status
let progAsk = VSLogic.execProgress(forStatus: "need_ask")
eq(progAsk.doneCount, 4, "need_ask -> 4 rows done")
eq(VSLogic.execProgress(forStatus: "done").doneCount, VSLogic.execStages.count, "done -> all done")
eq(VSLogic.execProgress(forStatus: "running").doneCount, 0, "running -> no pre-advance (stage events drive it)")
// P1 voice one-turn-one-clear: final replaces wholesale, never concatenated
eq(VSLogic.voiceReplace(previous: "old half sentence", final: "today's weather"), "today's weather", "final replaces wholesale")
// P0 need_ask renders a decision point (polled task json -> must emit ask with options)
let polledAsk = VSLogic.nextDecisionPoint(TaskView(taskId: "t1", status: "need_ask",
    question: "Which \"this\" do you mean?",
    options: [TaskOption(id: "edit", label: "Edit note"),
              TaskOption(id: "query", label: "Look it up"),
              TaskOption(id: "note", label: "Jot it down"),
              TaskOption(id: "commit", label: "Commit")]))
eq(polledAsk.kind, .ask, "need_ask -> ask decision")
eq(polledAsk.options.count, 4, "4 candidate buttons")
eq(polledAsk.options[0].id, "edit", "option id passed through (used for answer)")

print("\n----------------------------------------")
print("Result: \(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
