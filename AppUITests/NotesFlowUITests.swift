// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Notes typed while recording, timed and saved as they're typed, then cleaned up by the fake
/// model, reviewed and accepted.
final class NotesFlowUITests: MinutesUITestCase {
    @MainActor
    func testNotesWhileRecordingThenCleanUp() throws {
        launch(summarizing: true, tab: "notes")
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))

        // The recording's detail is its notes.
        let editor = app.textViews["notesEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("budget - bea wants nums fri\n")
        Thread.sleep(forTimeInterval: 1.5)
        editor.typeText("remote rubber ask chris")
        let folder = try XCTUnwrap(folders(in: meetings).first)
        let notesFile = folder.appendingPathComponent("notes.md")
        let typed = "budget - bea wants nums fri\nremote rubber ask chris"
        wait(for: "notes saved while recording") { self.saved(notesFile) == typed }
        stop.click()

        // Each line kept the time it was typed.
        let times = try noteTimes(in: folder)
        XCTAssertEqual(times.count, 2)
        let first = try XCTUnwrap(times[0])
        let second = try XCTUnwrap(times[1])
        XCTAssertGreaterThan(second, first + 1)

        // After the meeting, Space goes into the notes rather than the player.
        XCTAssertTrue(playPause.waitForExistence(timeout: 30))
        wait(for: "player ready") { self.playPause.isEnabled }
        let notes = app.textViews["notesEditor"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.click()
        notes.typeKey(.downArrow, modifierFlags: .command)
        notes.typeText(" ok")
        XCTAssertEqual(playPause.label, "Play")
        wait(for: "edit saved") { self.saved(notesFile) == typed + " ok" }
        XCTAssertEqual(try noteTimes(in: folder)[1], second, "Typing inside a line keeps its time.")

        // Clean up, review and accept.
        let cleanUp = app.buttons["cleanUpNotes"]
        wait(for: "clean up enabled") { cleanUp.isEnabled }
        cleanUp.click()
        let accept = app.buttons["cleanupAccept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["cleanupDiff"].exists)
        accept.click()
        let cleanedFile = folder.appendingPathComponent("notes-cleaned.md")
        wait(for: "cleanup saved") {
            (try? String(contentsOf: cleanedFile, encoding: .utf8))?.contains("- Remote Rubber Ask Chris Ok") == true
        }
        XCTAssertEqual(saved(notesFile), typed + " ok")
        XCTAssertTrue(app.descendants(matching: .any)["cleanedNotes"].waitForExistence(timeout: 10))
        let label = app.descendants(matching: .any)["cleanedNotesModel"]
        XCTAssertTrue(label.label.hasPrefix("Cleaned up by fake,"), label.label)
        app.terminate()
    }

    private func saved(_ file: URL) -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    private func noteTimes(in folder: URL) throws -> [Double?] {
        let data = try Data(contentsOf: folder.appendingPathComponent("notes.json"))
        return try JSONDecoder().decode(SavedNoteTimes.self, from: data).lines.map(\.seconds)
    }
}

private struct SavedNoteTimes: Decodable {
    var lines: [SavedNoteLine]
}

private struct SavedNoteLine: Decodable {
    var seconds: Double?
}
