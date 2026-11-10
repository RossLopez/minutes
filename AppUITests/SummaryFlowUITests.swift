// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// From a stopped recording to a summary written by the fake model, then a template edit, a
/// regenerated summary and the old one under Previous Versions.
final class SummaryFlowUITests: MinutesUITestCase {
    private var templates: URL {
        root.appendingPathComponent("Templates")
    }

    @MainActor
    private func summaryText(containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    @MainActor
    func testRecordThroughToSummaryAndRegenerate() throws {
        launch(summarizing: true, tab: "summary")
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        stop.click()

        // The summary follows the transcript by itself, written with the default template.
        let first = summaryText(containing: "written to: Summarize this meeting")
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        let folder = try XCTUnwrap(folders(in: meetings).first)
        let summary = folder.appendingPathComponent("summary.md")
        XCTAssertTrue(try String(contentsOf: summary, encoding: .utf8).contains("Send the notes."))

        // Edit the default template in Settings. It saves to its file as you type.
        app.typeKey(",", modifierFlags: .command)
        let templatesTab = app.toolbars.buttons["Summary Templates"]
        XCTAssertTrue(templatesTab.waitForExistence(timeout: 10))
        templatesTab.click()
        let editor = app.textViews["templateEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("Be brief. ")
        let template = templates.appendingPathComponent("Default.md")
        wait(for: "template saved") {
            (try? String(contentsOf: template, encoding: .utf8))?.hasPrefix("Be brief. ") == true
        }
        app.typeKey("w", modifierFlags: .command)

        // Regenerating uses the edited template and keeps the first summary as a previous version.
        let regenerate = app.buttons["summaryRegenerate"]
        XCTAssertTrue(regenerate.waitForExistence(timeout: 10))
        regenerate.click()
        XCTAssertTrue(summaryText(containing: "written to: Be brief.").waitForExistence(timeout: 30))
        let versions = folder.appendingPathComponent("summaries")
        wait(for: "previous version kept") { self.folders(in: versions).count == 1 }

        let menu = app.menuButtons["summaryPreviousVersions"]
        wait(for: "menu enabled") { menu.isEnabled }
        menu.click()
        let version = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Default")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10))
        version.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let previous = sheet.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Summarize this meeting"))
        XCTAssertTrue(previous.firstMatch.waitForExistence(timeout: 10))
        sheet.buttons["Done"].click()

        // After a relaunch the saved summary shows as soon as the meeting is opened.
        app.terminate()
        launch(summarizing: true, tab: "summary")
        let row = app.outlines["meetingList"].descendants(matching: .any)["meetingRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(summaryText(containing: "written to: Be brief.").waitForExistence(timeout: 10))
        app.terminate()
    }
}
