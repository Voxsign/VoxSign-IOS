//
//  UIVerify3.swift — ad-hoc acceptance helper test, round 3 (not product code).
//  Press-to-talk gesture: after waiting for the external window, hold the mic for 12s (the red bar is
//  captured by an external simctl io screenshot), then release and observe that it does not crash.
//

import XCTest

final class UIVerify3: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launch()
    }

    func testPressToTalkGesture() {
        let mic = app.buttons["vhs.mic"]
        guard mic.waitForExistence(timeout: 25) else { return }
        // External capture window: sleep 8s first, then hold for 12s (external simctl screenshots the red bar midway).
        sleep(8)
        mic.press(forDuration: 12)
        sleep(1)
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = "18-after-release"
        att.lifetime = .keepAlways
        add(att)
        // Must not crash after release; observe the voice status bar for 2 more seconds.
        sleep(2)
    }
}

//
//  V4Screenshots — ad-hoc acceptance test (not product code): V4 three-state screenshots.
//  Run:
//   TEST_TARGET_NAME=VoxSign xcodebuild test -project VoxSign.xcodeproj \
//     -scheme VoxSign -destination 'id=<simulator-id>' \
//     -derivedDataPath /tmp/vhs-v4-dd -resultBundlePath /tmp/vhs-v4-ui.xcresult \
//     -only-testing:VoxSignUITests/V4Screenshots/<method>
//  Notification / microphone alerts are SpringBoard-level: use an interruption monitor + actively poll SpringBoard buttons.
//

import XCTest

final class V4Screenshots: XCTestCase {

    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = true
        // Permission alerts: tap "Don't Allow" on notifications, "Allow" on microphone/speech-recognition; both are permanent decisions.
        addUIInterruptionMonitor(withDescription: "Permission alert") { alert in
            if alert.buttons["Don’t Allow"].exists { alert.buttons["Don’t Allow"].tap(); return true }
            if alert.buttons["Don't Allow"].exists { alert.buttons["Don't Allow"].tap(); return true }
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            if alert.buttons["OK"].exists { alert.buttons["OK"].tap(); return true }
            return false
        }
        app.launch()
        // Fallback: actively tap SpringBoard alert buttons (when the interruption monitor did not fire).
        sleep(1)
        for _ in 0..<5 {
            let dont = springboard.buttons["Don’t Allow"]
            let dont2 = springboard.buttons["Don't Allow"]
            let allow = springboard.buttons["Allow"]
            if dont.exists { dont.tap(); break }
            if dont2.exists { dont2.tap(); break }
            if allow.exists { allow.tap(); break }
            sleep(1)
        }
    }

    func shot(_ name: String) {
        sleep(1)
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// 01 Empty state: the shell side already cleared seeds and restarted cfprefsd. Screenshot the empty state on launch.
    func testEmptyState() {
        let input = app.descendants(matching: .any)["vhs.input"]
        guard input.waitForExistence(timeout: 25) else { return }
        // One harmless interaction to trigger the interruption monitor.
        input.tap()
        shot("01-home-empty")
    }

    /// 02 Chat state: the shell side already wrote a seed session to the app container plist. Screenshot the chat state on launch.
    func testChatState() {
        let input = app.descendants(matching: .any)["vhs.input"]
        guard input.waitForExistence(timeout: 25) else { return }
        input.tap()
        shot("02-chat-message")
    }

    /// 03 Hold state: an external shell loop runs simctl screenshot in parallel; this test only holds the mic for 8s.
    /// Does not assert the recording state (the red container may not appear when the simulator has no audio input).
    func testHoldTalking() {
        let input = app.descendants(matching: .any)["vhs.input"]
        guard input.waitForExistence(timeout: 25) else { return }
        input.tap()
        sleep(1)
        let mic = app.descendants(matching: .any)["vhs.mic"]
        guard mic.waitForExistence(timeout: 5) else { return }
        // The external capture loop takes a frame every 0.5s during this window.
        mic.press(forDuration: 8)
        sleep(1)
    }
}
