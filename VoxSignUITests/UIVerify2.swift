//
//  UIVerify2.swift — ad-hoc acceptance helper test, round 2 (not product code).
//  Coverage: AI bubble info row (receipt restored as a harness bubble after switching back) /
//            pop the … menu / user-bubble attachment chip (typed directly into TextEditor, no clipboard) /
//            session list / swipe-to-delete.
//  Precondition: a self-hosted server (127.0.0.1:8897/m7-token) was written to UserDefaults in the previous round, with history sessions.
//

import XCTest

final class UIVerify2: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launch()
    }

    func shot(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    func testSecondPass() {
        let input = app.textFields["vhs.input"]
        guard input.waitForExistence(timeout: 25) else { return }
        sleep(1)

        // 1) Send another message to get a fresh receipt
        input.tap()
        input.typeText("verify2 second run")
        if app.buttons["vhs.send"].waitForExistence(timeout: 3) {
            app.buttons["vhs.send"].tap()
        }
        let done = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Done' OR label CONTAINS 'Undo'")
        ).firstMatch
        _ = done.waitForExistence(timeout: 40)
        sleep(1)

        // 2) Session list -> new session -> back to the list -> switch back to the old session (receipt restored as a harness bubble with info row)
        app.buttons["vhs.sessions"].tap()
        sleep(1)
        if app.buttons["vhs.session.new"].waitForExistence(timeout: 5) {
            app.buttons["vhs.session.new"].tap()
        }
        sleep(1)
        // Back to the old session: open the list -> tap the second row (old session)
        app.buttons["vhs.sessions"].tap()
        sleep(1)
        // Region 12: session list (multiple sessions)
        shot("12-session-list")
        let cells = app.cells
        _ = cells.firstMatch.waitForExistence(timeout: 5)
        if cells.count >= 2 {
            cells.element(boundBy: 1).tap()
        } else {
            cells.firstMatch.tap()
        }
        sleep(2)
        // Region 13: back on the old session -> AI bubble light info row (time + … menu, no speaker/volume)
        shot("13-harness-bubble-info-row")

        // 3) Tap the small ellipsis below the AI bubble (info-row menu)
        let win = app.windows.firstMatch.frame
        var ell: XCUIElement?
        for b in app.buttons.allElementsBoundByIndex {
            let f = b.frame
            guard f.width <= 30, f.height <= 30,
                  f.midY > 120, f.midY < win.midY,
                  b.identifier != "vhs.send", b.identifier != "vhs.mic", b.identifier != "vhs.attach"
            else { continue }
            ell = b
        }
        ell?.tap()
        sleep(1)
        // Region 14: AI bubble … menu (Copy / Speak / Share)
        shot("14-bubble-menu")
        if app.buttons["Copy"].waitForExistence(timeout: 3) {
            app.buttons["Copy"].tap()
            sleep(1)
        }

        // 4) Add a resource: type text directly into the TextEditor -> Add -> user-bubble chip
        app.buttons["vhs.attach"].tap()
        sleep(1)
        let editor = app.textViews.firstMatch
        if editor.waitForExistence(timeout: 5) {
            editor.tap()
            editor.typeText("attached note from verify")
        }
        let addBtns = app.buttons.matching(NSPredicate(format: "label == 'Add'"))
        if addBtns.firstMatch.waitForExistence(timeout: 3) {
            addBtns.firstMatch.tap()
        }
        sleep(1)
        // 5) Send the message with the attachment
        input.tap()
        input.typeText("send with attachment")
        if app.buttons["vhs.send"].waitForExistence(timeout: 3) {
            app.buttons["vhs.send"].tap()
        }
        _ = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Done' OR label CONTAINS 'Undo'")
        ).firstMatch.waitForExistence(timeout: 30)
        sleep(2)
        // Region 15: user-bubble attachment chip (small gray tag)
        shot("15-user-bubble-chip")

        // 6) Session list: swipe-delete one session
        app.buttons["vhs.sessions"].tap()
        sleep(1)
        _ = cells.firstMatch.waitForExistence(timeout: 5)
        if cells.count >= 1 {
            cells.firstMatch.swipeLeft()
            sleep(1)
            let del = app.buttons["Delete"]
            if del.waitForExistence(timeout: 3) { del.tap() }
            sleep(1)
        }
        // Region 16: session list (after delete)
        shot("16-session-list-after-delete")
    }
}
