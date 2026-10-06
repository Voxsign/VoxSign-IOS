//
//  UIVerifyV2.swift — ad-hoc acceptance helper test (added by the accepting party, not product code, untracked).
//  Purpose: drive one real chat on the simulator to verify the AI bubble light info row
//        ("only time + … menu, no usage row") (when the server omits costTokens), and that the receipt card renders normally.
//  Region-by-region XCTAttachment(keepAlways) screenshots.
//  Run:
//   TEST_TARGET_NAME=VoxSign xcodebuild test -project VoxSign.xcodeproj \
//     -scheme VoxSign -destination 'id=<simulator-id>' \
//     -derivedDataPath /tmp/vhs-sim-dd -resultBundlePath /tmp/vhs-v2-ui.xcresult \
//     -only-testing:VoxSignUITests/UIVerifyV2/testChatInfoRowNoCost
//

import XCTest

final class UIVerifyV2: XCTestCase {

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

    /// Ensure the self-hosted server 127.0.0.1:8897 / m7-token is configured (idempotent: skip adding if present).
    private func ensureSelfHosted() {
        let input = app.textFields["vhs.input"]
        guard input.waitForExistence(timeout: 25) else {
            XCTFail("vhs.input did not appear")
            return
        }
        app.buttons["vhs.more"].tap()
        _ = app.buttons["Settings"].waitForExistence(timeout: 5)
        app.buttons["Settings"].tap()
        sleep(1)

        _ = app.buttons["Self-hosted"].waitForExistence(timeout: 5)
        app.buttons["Self-hosted"].tap()
        sleep(1)

        // Skip adding if "Local Mac" was already configured.
        let existing = app.staticTexts["Local Mac"]
        if !existing.waitForExistence(timeout: 3) {
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
            _ = app.staticTexts["Local Mac"].waitForExistence(timeout: 15)
            sleep(1)
        }
        // Done -> back to chat
        app.buttons["Done"].firstMatch.tap()
        sleep(1)
    }

    func testChatInfoRowNoCost() {
        let input = app.textFields["vhs.input"]
        guard input.waitForExistence(timeout: 25) else {
            XCTFail("vhs.input did not appear")
            return
        }
        // Region 1: empty state / top bar (title VoxSign) + input bar
        sleep(1)
        shot("01-home-topbar")

        ensureSelfHosted()

        // -- Send a message and wait for the AI receipt --
        input.tap()
        input.typeText("jot down verify v2 cost decoupling")
        if app.buttons["vhs.send"].waitForExistence(timeout: 3) {
            app.buttons["vhs.send"].tap()
        }
        // Receipt card: wait for any of "Done" / "Needs Input" / "Undo"
        let done = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Done' OR label CONTAINS 'Undo' OR label CONTAINS 'Needs Input'")
        ).firstMatch
        _ = done.waitForExistence(timeout: 45)
        sleep(1)
        // Region 2: AI bubble info row (time + …, no usage row) + receipt card
        shot("02-ai-bubble-inforow")

        // -- AI bubble "…" menu: a small ellipsis button in the lower half --
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
        // Region 3: AI message action menu (Copy / Speak / Share)
        shot("03-ai-bubble-menu")
        if app.buttons["Copy"].waitForExistence(timeout: 3) {
            app.buttons["Copy"].tap()
        }
        sleep(1)
    }
}
