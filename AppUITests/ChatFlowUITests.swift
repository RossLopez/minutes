// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import XCTest

/// Searching meeting text, asking about meetings with the fake model, following a citation back
/// to the transcript, a meeting's Ask tab, and export.
final class ChatFlowUITests: MinutesUITestCase {
    @MainActor
    private func text(containing text: String) -> XCUIElement {
        // Markdown paragraphs are combined elements, whose text can be in the label.
        app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch
    }

    @MainActor
    private func recordMeeting() {
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        stop.click()
        // Read from disk, since the Ask tab shows no transcript lines.
        wait(for: "transcribed") {
            self.folders(in: self.meetings).first.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            } == true
        }
        // The index updates moments after the transcript is saved.
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor
    private func ask(_ question: String) {
        // A field that grows to several lines can be a text field or a text view.
        let field = app.descendants(matching: .any)["chatQuestion"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText(question + "\n")
    }

    @MainActor
    func testSearchThenChatAndFollowACitation() throws {
        launch(summarizing: true)
        recordMeeting()

        // Sidebar search finds words in the transcript, not just the title, and shows where.
        app.typeKey("f", modifierFlags: .command)
        app.typeText("thursd")
        // A row is one combined element, so its snippet is part of its value. The title doesn't
        // hold the word, so a match means the snippet is shown.
        let matching = NSPredicate(format: "value CONTAINS[c] %@", "thursday")
        let found = app.outlines["meetingList"].staticTexts.matching(matching).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 15))
        app.typeKey(.escape, modifierFlags: [])

        // A chat across meetings, answered by the fake model from the indexed transcript.
        app.outlines.staticTexts["Chat"].firstMatch.click()
        let newChat = app.buttons["newChatEmpty"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.click()
        ask("When will the numbers arrive?")
        let answer = text(containing: "A fake answer from")
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        XCTAssertFalse(text(containing: "[9]").exists, "A citation of a source that doesn't exist is dropped")

        // The chat is saved as Markdown, its sources linking into the meeting.
        let chats = root.appendingPathComponent("Chats")
        wait(for: "chat saved") { self.folders(in: chats).count == 1 }
        let file = try String(contentsOf: XCTUnwrap(folders(in: chats).first), encoding: .utf8)
        XCTAssertTrue(file.contains("## You\n\nWhen will the numbers arrive?"))
        XCTAssertTrue(file.contains("(minutes://meeting/"))

        // Following the source opens the meeting's transcript. Sources start out shown.
        XCTAssertTrue(app.buttons["chatSourcesToggle"].firstMatch.waitForExistence(timeout: 10))
        let source = app.buttons["chatSource"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.click()
        XCTAssertTrue(app.descendants(matching: .any)["transcriptList"].waitForExistence(timeout: 10))
        XCTAssertTrue(title.waitForExistence(timeout: 10))

        // Reopened after a relaunch, the chat reads back from its file.
        app.terminate()
        launch(summarizing: true)
        app.outlines.staticTexts["Chat"].firstMatch.click()
        let row = app.descendants(matching: .any)["chatRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(text(containing: "A fake answer from").waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testAskTabAndExport() throws {
        let exports = root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        launch(summarizing: true, tab: "ask", environment: ["MINUTES_TEST_EXPORT": exports.path])
        recordMeeting()

        // The Ask tab is about this meeting alone, and saves its chat in the meeting's folder.
        ask("What is due on Friday?")
        XCTAssertTrue(text(containing: "A fake answer from").waitForExistence(timeout: 30))
        let folder = try XCTUnwrap(folders(in: meetings).first)
        let meetingChats = folder.appendingPathComponent("chats")
        wait(for: "chat saved with the meeting") { self.folders(in: meetingChats).count == 1 }

        // Export copies the meeting as Markdown, then saves it as a file.
        NSPasteboard.general.clearContents()
        app.typeKey("e", modifierFlags: .command)
        let copy = app.buttons["exportCopy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        wait(for: "meeting read") { copy.isEnabled }
        copy.click()
        wait(for: "copied") { NSPasteboard.general.string(forType: .string)?.contains("## Transcript") == true }
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(copied.contains("Friday"))
        XCTAssertTrue(copied.hasPrefix("# "))

        app.buttons["exportSave"].click()
        wait(for: "file saved") { self.folders(in: exports).count == 1 }
        let saved = try String(contentsOf: XCTUnwrap(folders(in: exports).first), encoding: .utf8)
        XCTAssertEqual(saved, copied)
        app.terminate()
    }
}
