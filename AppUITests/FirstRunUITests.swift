// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The first-run flow, from the welcome to recording. `MINUTES_FIRST_RUN` shows it without reading
/// or writing this Mac's settings, so nothing is typed into the name field here.
final class FirstRunUITests: MinutesUITestCase {
    /// A static text's words are in its value on macOS, and a heading's in its label. Headings
    /// don't match `staticTexts`, so any element type.
    @MainActor
    private func text(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
    }

    @MainActor
    func testWalkThroughFirstRun() {
        launch(environment: ["MINUTES_FIRST_RUN": "1"])
        let next = app.buttons["firstRunContinue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(text("Welcome to Minutes").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["firstRunSkip"].exists, "The welcome can't be skipped")
        next.click()

        // The name, filled in from Settings.
        let name = app.textFields["firstRunName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Robin")
        next.click()

        // The same permission rows as Settings, and Back returns to the name.
        XCTAssertTrue(text("System Audio Recording").waitForExistence(timeout: 5))
        app.buttons["firstRunBack"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        next.click()
        XCTAssertTrue(text("System Audio Recording").waitForExistence(timeout: 5))
        next.click()

        // A model is offered and preselected. Skipping downloads nothing.
        let model = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'firstRunModel-'")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        app.buttons["firstRunSkip"].click()

        XCTAssertTrue(text("Recording consent").waitForExistence(timeout: 5))
        next.click()

        XCTAssertTrue(text("You're ready").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "download in the background"))
            .firstMatch.exists)
        next.click()

        // Done: the window is ready to record.
        XCTAssertTrue(next.waitForNonExistence(timeout: 5))
        XCTAssertTrue(record.isHittable)
        app.terminate()
    }
}
