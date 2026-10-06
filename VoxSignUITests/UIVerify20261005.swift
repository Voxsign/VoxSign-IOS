//
//  UIVerify20261005.swift — ad-hoc acceptance helper test (added by the package runner, not product code).
//  Purpose: drive navigation to each acceptance region on the simulator, screenshot region by region (XCTAttachment keepAlways),
//        and exercise add-resource / multi-session / …-menu copy / session switch & delete.
//  Run:
//   TEST_TARGET_NAME=VoxSign xcodebuild test -project VoxSign.xcodeproj \
//     -scheme VoxSign -destination 'id=<simulator-id>' \
//     -derivedDataPath /tmp/vhs24-test-dd -resultBundlePath /tmp/vhs24-ui.xcresult \
//     -only-testing:VoxSignUITests/UIVerify20261005/testVerifyAllRegions
//

import XCTest

final class UIVerify20261005: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launch()
    }

    /// Screenshot with keepAlways; export later via xcresulttool.
    func shot(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    func testVerifyAllRegions() {
        let input = app.textFields["vhs.input"]
        guard input.waitForExistence(timeout: 25) else {
            XCTFail("vhs.input did not appear")
            return
        }
        sleep(1)
        // Region 1: top bar (status dot + title + left/right entries) + minimal input bar trio + empty-state greeting
        shot("01-home-empty")

        // -- Configure a self-hosted server (Settings -> Self-hosted -> Add server -> IP) --
        app.buttons["vhs.more"].tap()
        _ = app.buttons["Settings"].waitForExistence(timeout: 5)
        app.buttons["Settings"].tap()
        sleep(1)
        // Region 2: Settings (cloud default state)
        shot("02-settings-cloud")

        _ = app.buttons["Self-hosted"].waitForExistence(timeout: 5)
        app.buttons["Self-hosted"].tap()
        sleep(1)
        _ = app.buttons["Add server"].waitForExistence(timeout: 5)
        app.buttons["Add server"].tap()
        sleep(1)
        let ipBtn = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'IP address'")
        ).firstMatch
        if ipBtn.waitForExistence(timeout: 5) { ipBtn.tap() }
        sleep(1)

        let nameF = app.textFields["Name (e.g. Office Mac)"]
        let baseF = app.textFields["http://192.168.x.x:8897"]
        let tokF = app.secureTextFields["Bearer Token (optional)"]
        if nameF.waitForExistence(timeout: 5) {
            nameF.tap(); nameF.typeText("Local Mac")
            baseF.tap(); baseF.typeText("http://127.0.0.1:8897")
            tokF.tap(); tokF.typeText("m7-token")
        }
        let save = app.buttons["Save and check connection"]
        if save.waitForExistence(timeout: 5) { save.tap() }
        // Wait for the server row (saved only after the connectivity check passes)
        let row = app.staticTexts["Local Mac"]
        _ = row.waitForExistence(timeout: 15)
        sleep(1)
        // Region 3: Settings (self-hosted connected state)
        shot("03-settings-selfhosted")
        // Done -> back to chat
        app.buttons["Done"].firstMatch.tap()
        sleep(1)

        // -- Send a message and wait for the AI receipt --
        input.tap()
        input.typeText("verify note 20261005")
        if app.buttons["vhs.send"].waitForExistence(timeout: 3) {
            app.buttons["vhs.send"].tap()
        }
        let done = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Done' OR label CONTAINS 'Undo' OR label CONTAINS 'No'")
        ).firstMatch
        _ = done.waitForExistence(timeout: 45)
        sleep(1)
        // Region 4: AI message info row (usage · time · …, no bell/speaker) + receipt card + user bubble
        shot("04-chat-receipt")

        // -- AI bubble "…" menu: locate the small ellipsis button in the lower half of the window --
        let win = app.windows.firstMatch.frame
        var bubbleEllipsis: XCUIElement?
        for b in app.buttons.allElementsBoundByIndex {
            let f = b.frame
            guard f.width <= 30, f.height <= 30,
                  f.midY > win.midY, f.midY < win.maxY - 70,
                  b.identifier != "vhs.send", b.identifier != "vhs.mic", b.identifier != "vhs.attach"
            else { continue }
            bubbleEllipsis = b
        }
        bubbleEllipsis?.tap()
        sleep(1)
        // Region 5: AI message action menu (Copy / Speak / Share)
        shot("05-ai-bubble-menu")
        if app.buttons["Copy"].waitForExistence(timeout: 3) {
            app.buttons["Copy"].tap()
        }
        sleep(1)

        // -- Add-resource panel: ＋ -> Read from clipboard (the AI text just copied) -> Add --
        app.buttons["vhs.attach"].tap()
        sleep(1)
        if app.buttons["Read from clipboard"].waitForExistence(timeout: 5) {
            app.buttons["Read from clipboard"].tap()
            sleep(1)
        }
        // Region 6: add-resource panel (four entries + text read from clipboard)
        shot("06-attach-panel")
        let addBtns = app.buttons.matching(NSPredicate(format: "label == 'Add'"))
        if addBtns.firstMatch.waitForExistence(timeout: 3) {
            addBtns.firstMatch.tap()
        }
        sleep(1)
        // Back to chat: send the message with the attachment -> the user bubble shows an attachment chip
        input.tap()
        input.typeText("with attachment")
        if app.buttons["vhs.send"].waitForExistence(timeout: 3) {
            app.buttons["vhs.send"].tap()
        }
        sleep(3)
        // Region 7: user-bubble attachment chip
        shot("07-user-bubble-chip")

        // -- Session list -> new session --
        app.buttons["vhs.sessions"].tap()
        sleep(1)
        // Region 8: session list (>= 1 history item)
        shot("08-session-list")
        if app.buttons["vhs.session.new"].waitForExistence(timeout: 5) {
            app.buttons["vhs.session.new"].tap()
        }
        sleep(1)
        // Region 9: new-session empty state (one greeting line)
        shot("09-new-session-empty")

        // -- Open the list again: swipe-delete the new empty session, then switch back to the old one --
        app.buttons["vhs.sessions"].tap()
        sleep(1)
        let cells = app.cells
        _ = cells.firstMatch.waitForExistence(timeout: 5)
        if cells.count >= 2 {
            cells.firstMatch.swipeLeft()
            sleep(1)
            let del = app.buttons["Delete"]
            if del.waitForExistence(timeout: 3) { del.tap() }
            sleep(1)
        }
        // Tap the remaining old-session row -> switch back
        if cells.firstMatch.waitForExistence(timeout: 3) {
            cells.firstMatch.tap()
        }
        sleep(2)
        // Region 10: switched back to the old session (history bubbles restored)
        shot("10-switch-back")
    }
}
