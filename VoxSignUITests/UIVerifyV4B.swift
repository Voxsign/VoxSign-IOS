//
//  UIVerifyV4B.swift — V4 plan-B ad-hoc acceptance helper test (not product code).
//  Purpose: verify and screenshot the three core V4 plan-B states on the simulator:
//        ① default state (empty state + ＋/🎤 big button / ⌨ input bar)
//        ② hold state (full-screen waveform: white bg + red waveform + "Listening…" + "release to send · slide up to cancel")
//        ③ text mode (tap ⌨ -> input field + send arrow)
//  Run:
//   TEST_TARGET_NAME=VoxSign xcodebuild test -project VoxSign.xcodeproj \
//     -scheme VoxSign -destination 'id=<simulator-id>' \
//     -derivedDataPath /tmp/vhs-v4-dd-test -resultBundlePath /tmp/vhs-v4-ui.xcresult \
//     -only-testing:VoxSignUITests/UIVerifyV4B/testV4BVerify
//

import XCTest

final class UIVerifyV4B: XCTestCase {

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

    func testV4BVerify() {
        // Dismiss the first-launch system notification permission alert (springboard level)
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = sb.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            let allow = alert.buttons["Allow"]
            if allow.exists {
                allow.tap()
            }
            sleep(1)
        }

        // ① Default state: wait for the input bar (an offline banner shows "Offline"; screenshot it too —
        //    the top-bar machine name and top-right new-session button are always visible)
        let mic = app.descendants(matching: .any)["vhs.mic"]
        let offline = app.descendants(matching: .any)["vhs.offline"]
        _ = mic.waitForExistence(timeout: 10)
        sleep(2)
        shot("01-v6-default")

        // ④ V6 left drawer: tap the top-left session entry -> drawer slides in -> screenshot -> close (independent of mic/online)
        let sessions = app.descendants(matching: .any)["vhs.sessions"]
        if sessions.waitForExistence(timeout: 5) {
            sessions.tap()
            sleep(1)
            shot("05-v6-drawer")
            let close = app.descendants(matching: .any)["vhs.session.close"]
            if close.exists { close.tap() }
            sleep(1)
        }

        // ② Hold state (only when the voice big button exists — skipped in the offline-banner case)
        guard mic.exists else {
            if offline.exists { shot("02-v6-offline") }
            return
        }
        // Press and hold the voice button; screenshot the waveform UI mid-hold on a helper thread
        let holdShot = expectation(description: "hold-shot")
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 2.0)
            guard let self = self else { return }
            let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            att.name = "02-v4-hold-wave"
            att.lifetime = .keepAlways
            DispatchQueue.main.async {
                self.add(att)
                holdShot.fulfill()
            }
        }
        mic.press(forDuration: 4.0)
        wait(for: [holdShot], timeout: 12)

        // ③ Text mode: tap ⌨ -> input field appears
        let kb = app.descendants(matching: .any)["vhs.keyboard"]
        if kb.waitForExistence(timeout: 5) { kb.tap() }
        let input = app.textFields["vhs.input"]
        _ = input.waitForExistence(timeout: 8)
        sleep(1)
        shot("03-v4-textmode")

        // Type text -> send arrow appears
        input.tap()
        input.typeText("hello v4")
        sleep(1)
        shot("04-v4-text-typed")
    }
}
