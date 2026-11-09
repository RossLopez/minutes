// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Naming, moving and merging speakers, with the fake diarizer splitting the other side's line in two.
final class SpeakerFlowUITests: MinutesUITestCase {
    @MainActor
    private var lines: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "transcriptLine")
    }

    @MainActor
    private func label(ofLine index: Int) -> String {
        lines.element(boundBy: index).label
    }

    @MainActor
    func testNameMoveAndMergeSpeakers() throws {
        try seedLongMeeting()
        launch(diarizing: true)
        let row = NSPredicate(format: "value BEGINSWITH %@", "Long Meeting")
        let meeting = app.outlines["meetingList"].staticTexts.matching(row).firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 10))
        meeting.click()
        let transcribe = app.buttons["transcriptTranscribe"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 10))
        transcribe.click()

        // Me, then two other voices, the second taking over at 61 seconds.
        wait(for: "three lines") { self.lines.count == 3 }
        XCTAssertTrue(label(ofLine: 0).hasPrefix("Robin"))
        XCTAssertTrue(label(ofLine: 1).hasPrefix("Speaker 1"))
        XCTAssertTrue(label(ofLine: 2).hasPrefix("Speaker 2"))

        // Naming a speaker names all their lines, in the app and in the files.
        lines.element(boundBy: 1).rightClick()
        app.menuItems["Name Speaker…"].click()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("Dana\n")
        wait(for: "named") { self.label(ofLine: 1).hasPrefix("Dana") }
        let folder = try XCTUnwrap(folders(in: meetings).first)
        let readable = folder.appendingPathComponent("transcript.md")
        wait(for: "transcript.md has the name") {
            (try? String(contentsOf: readable, encoding: .utf8))?.contains("Dana") == true
        }

        // One line can move to someone else, or to someone new.
        try changeSpeaker(ofLine: 2, to: "Dana")
        wait(for: "moved to Dana") { self.label(ofLine: 2).hasPrefix("Dana") }
        try changeSpeaker(ofLine: 2, to: "New Speaker")
        wait(for: "moved to someone new") { self.label(ofLine: 2).hasPrefix("Speaker 2") }

        // Merging gives every line of one speaker to the other.
        lines.element(boundBy: 2).rightClick()
        app.menuItems["Name Speaker…"].click()
        let merge = app.descendants(matching: .any)["speakerMergeMenu"]
        XCTAssertTrue(merge.waitForExistence(timeout: 10))
        merge.click()
        app.menuItems["Dana"].click()
        wait(for: "merged") { self.label(ofLine: 2).hasPrefix("Dana") }

        let transcript = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("transcript.json")),
        ) as? [String: Any]
        let segments = try XCTUnwrap(transcript?["segments"] as? [[String: Any]])
        let speakers = segments.compactMap { $0["speaker"] as? String }
        XCTAssertEqual(speakers, ["me", "speaker-1", "speaker-1"])
        let markdown = try String(contentsOf: readable, encoding: .utf8)
        XCTAssertFalse(markdown.contains("Speaker 2"))

        // Voices are remembered only when the user turns that on.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Speakers").path))
        app.terminate()
    }

    @MainActor
    private func changeSpeaker(ofLine index: Int, to name: String) throws {
        lines.element(boundBy: index).rightClick()
        let change = app.menuItems["Change Speaker"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        change.hover()
        let target = app.menuItems[name]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.click()
    }
}
