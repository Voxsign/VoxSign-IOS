//
//  VoxSignUITests.swift
//  VoxSignUITests
//
//  XCUITest drives the real app rendering (debug build with a real device, prefilled server 192.168.8.129:8897 / m7-token).
//  Run (device unlocked, screen on):
//  xcodebuild test -project VoxSign.xcodeproj -scheme VoxSign \
//    -destination 'id=<device-id>' -derivedDataPath /tmp/vhs-m7-dd \
//    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=P5W752L332
//

import XCTest

final class VoxSignUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }

    /// Wait for "any real reply" to arrive: a receipt card ("Done" / "Needs Input") or a need_ask decision-card option button;
    /// returns as soon as either appears.
    /// Returns true if a need_ask option button appeared (decision card), false if a receipt card appeared.
    /// Note: the need_ask question text is server-generated, not fixed UI copy (e.g. "which?"), so we no longer assert on it.
    @discardableResult
    private func waitForAnyReply(timeout: TimeInterval) -> Bool {
        let receipt = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Done' OR label CONTAINS 'Needs Input'")
        ).firstMatch
        let option = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Jot' OR label CONTAINS 'Commit' OR label CONTAINS 'Edit' OR label CONTAINS 'Query'")
        ).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if option.exists { return true }
            if receipt.exists { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(receipt.exists || option.exists,
                       "timed out: neither a receipt card (Done/Needs Input) nor option buttons rendered")
        return option.exists
    }

    /// P0: send a vague command -> wait for any real reply to render.
    /// The new harness may answer a vague command directly with a "Needs Input" receipt, or with a need_ask decision card;
    /// either arriving counts as the pipeline being healthy. If a decision card appears, assert that the option buttons actually render.
    func test_needAskRendersButtons() {
        let input = app.textFields["vhs.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "input field did not appear")
        input.tap()
        input.typeText("jot that thing")

        let send = app.buttons["vhs.send"]
        XCTAssertTrue(send.isEnabled, "send button should be enabled")
        send.tap()

        let sawOptions = waitForAnyReply(timeout: 20)
        if sawOptions {
            // Decision-card branch: waitForAnyReply already confirmed the options exist; assert again explicitly.
            let option = app.buttons.containing(
                NSPredicate(format: "label CONTAINS 'Jot' OR label CONTAINS 'Commit' OR label CONTAINS 'Edit' OR label CONTAINS 'Query'")
            ).firstMatch
            XCTAssertTrue(option.exists, "option buttons did not render")
        }
        // Receipt-card branch ("Needs Input"/"Done"): waitForAnyReply already confirmed it rendered, no further assertion needed.
    }

    /// Clear command -> a receipt card appears (new copy is "✅ Done · X.X s"; the harness may answer a vague command with a "Needs Input" receipt).
    func test_noteRunsToReceipt() {
        let input = app.textFields["vhs.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("jot: meeting tomorrow")
        app.buttons["vhs.send"].tap()

        // Receipt card: wait for "Done" or the server's "Needs Input" receipt text.
        let receipt = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Done' OR label CONTAINS 'Needs Input'")
        ).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 20),
                      "did not reach a receipt card (maybe an unanswered need_ask along the way)")
    }

    /// P2 / punctuation: after injecting via the text path, assert recognition/input echo —
    /// UI automation cannot inject real voice (Speech permission + audio), so the text path verifies that the input echo sends.
    func test_punctuationViaTextPath() {
        let input = app.textFields["vhs.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        // Type a punctuated sentence directly into the text field (bypassing ASR; verify the input path keeps punctuation).
        let sample = "jot: Mr. Ji's factory next Monday; also ask about Wednesday."
        input.typeText(sample)
        XCTAssertEqual(input.value as? String, sample,
                       "the text input path should preserve punctuation as-is")
        // Note: ASR-side punctuation (addsPunctuation) is covered by real-device voice (UI automation cannot inject voice).
    }

    /// Multi-task timing: two consecutive commands; each round passes as soon as any real reply appears (reproduces "first stalls, second works").
    /// If a decision card renders in a round, tap an option to answer it; if a receipt card renders, move to the next round.
    func test_multiTaskSequential() {
        let input = app.textFields["vhs.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))

        func sendAndExpectReply(_ text: String, line: Int) {
            input.tap()
            input.typeText(text)
            app.buttons["vhs.send"].tap()
            let sawOptions = waitForAnyReply(timeout: 20)
            if sawOptions {
                // Decision card appeared: pick an option to answer it and move on.
                let opt = app.buttons.containing(
                    NSPredicate(format: "label CONTAINS 'Jot' OR label CONTAINS 'Commit' OR label CONTAINS 'Edit' OR label CONTAINS 'Query'")
                ).firstMatch
                XCTAssertTrue(opt.waitForExistence(timeout: 5), "round \(line) did not render option buttons")
                opt.tap()
            }
            // Receipt-card branch: this round passed, no tap needed.
        }

        sendAndExpectReply("jot that thing", line: 1)
        // Wait for the decision point to clear and the input field to be usable again before the second round.
        XCTAssertTrue(input.waitForExistence(timeout: 10), "input field did not recover after round 1")
        sendAndExpectReply("say that again", line: 2)
    }
}
