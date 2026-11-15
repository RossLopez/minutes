// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The README's screenshots, of the made-up demo library, in light and dark. Each is kept as an
/// attachment on the test result, which `scripts/make-screenshots.sh` saves to `docs/screenshots/`.
/// Skipped unless that script runs it, so the usual test runs stay quick.
final class ScreenshotUITests: MinutesUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MINUTES_SCREENSHOTS"] == "1",
                          "Run scripts/make-screenshots.sh to take the screenshots.")
    }

    @MainActor
    func testLightScreenshots() throws {
        try takeScreenshots(appearance: "light")
    }

    @MainActor
    func testDarkScreenshots() throws {
        try takeScreenshots(appearance: "dark")
    }

    @MainActor
    func testFirstRunScreenshots() {
        for appearance in ["light", "dark"] {
            launch(environment: environment(for: appearance).merging(["MINUTES_FIRST_RUN": "1"]) { $1 })
            XCTAssertTrue(app.buttons["firstRunContinue"].waitForExistence(timeout: 10))
            settle()
            snap("first-run-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    private func takeScreenshots(appearance: String) throws {
        try DemoLibrary.write(to: root) { url, seconds in
            try writeSilence(to: url, seconds: seconds)
        }
        launch(summarizing: true, tab: nil, environment: environment(for: appearance))

        let row = app.outlines["meetingList"].descendants(matching: .any)["meetingRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        app.radioButtons["Summary"].firstMatch.click()
        XCTAssertTrue(text("Key points and decisions").waitForExistence(timeout: 10))
        settle()
        snap("summary-\(appearance)")

        app.radioButtons["Transcript"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["transcriptList"].waitForExistence(timeout: 10))
        settle()
        snap("transcript-\(appearance)")

        clickRecord()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        // Long enough for the clock and the fake audio's meters to move.
        Thread.sleep(forTimeInterval: 4)
        snap("recording-\(appearance)")
        stop.click()
        XCTAssertTrue(record.waitForExistence(timeout: 10))

        app.outlines.staticTexts["Chat"].firstMatch.click()
        let chat = app.descendants(matching: .any)["chatRow"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.click()
        XCTAssertTrue(text("soft launch").waitForExistence(timeout: 10))
        settle()
        snap("chat-\(appearance)")
    }

    /// After the window is resized, Record is sometimes found with no frame for a while, so this
    /// waits for it, then clicks where it is in the window's toolbar.
    @MainActor
    private func clickRecord() {
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        for _ in 0 ..< 20 where !record.isHittable {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if record.isHittable {
            record.click()
        } else {
            let window = app.windows["main"]
            window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
                .withOffset(CGVector(dx: -26, dy: 26)).click()
        }
    }

    /// The app's appearance, whatever the system's, and the window's size, whatever it was left at.
    private func environment(for appearance: String) -> [String: String] {
        [
            "MINUTES_APPEARANCE": appearance,
            "MINUTES_WINDOW_SIZE": "{1120, 720}",
            "MINUTES_FAKE_LLM_NAME": "Gemma 4 12B",
        ]
    }

    @MainActor
    private func text(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    /// Lets animations and the scroll bars fade before a screenshot.
    private func settle() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    @MainActor
    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
