// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The record → save → transcript → manage flow and the player, using the app's fake audio sources
/// and transcription engine, since nothing can grant audio permissions to a test.
///
/// A single step can take several seconds on CI, so nothing here relies on short audio still
/// playing, or on transcribing taking any particular time. Checks that need playback use a long
/// meeting seeded before launch, and the fake engine holds each track until `releaseFile` exists.
final class RecordFlowUITests: MinutesUITestCase {
    @MainActor
    func testRecordThenRenameAndTrash() throws {
        launch()
        try recordFirstMeeting()
        let renamed = try renameFirstMeeting()
        recordSecondMeetingAndLeaveATitleHalfTyped()
        checkTrash(firstMeeting: renamed)
        app.terminate()
    }

    @MainActor
    func testPlayerWithALongMeeting() throws {
        try seedLongMeeting()
        launch()
        let row = NSPredicate(format: "value BEGINSWITH %@", "Long Meeting")
        let longMeeting = app.outlines["meetingList"].staticTexts.matching(row).firstMatch
        XCTAssertTrue(longMeeting.waitForExistence(timeout: 10))
        longMeeting.click()
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        wait(for: "player ready") { self.playPause.isEnabled }

        checkKeyboardAndSpeed()
        try renameWhilePlaying()

        // A new recording pauses playback, and shows its notes in place of the meeting.
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["notesEditor"].waitForExistence(timeout: 10))
        let renamed = NSPredicate(format: "value BEGINSWITH %@", "Budget Review")
        app.outlines["meetingList"].staticTexts.matching(renamed).firstMatch.click()
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        wait(for: "paused by recording") { self.playPause.label == "Play" }
        stop.click()
        XCTAssertTrue(app.staticTexts["recordingSaved"].waitForExistence(timeout: 20))
        app.terminate()
    }

    @MainActor
    private func recordFirstMeeting() throws {
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        // Let some audio reach the files.
        Thread.sleep(forTimeInterval: 2)
        stop.click()

        XCTAssertTrue(app.staticTexts["recordingSaved"].waitForExistence(timeout: 20))
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        let audio = try XCTUnwrap(folders(in: meetings).first).appendingPathComponent("audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("mic-raw.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("system.m4a").path))

        // The finished meeting opens by itself, with the player ready.
        XCTAssertTrue(app.outlines["meetingList"].waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        wait(for: "player ready") { self.playPause.isEnabled }
    }

    @MainActor
    private func renameFirstMeeting() throws -> URL {
        try rename(to: "Budget Review")
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        return try XCTUnwrap(folders(in: meetings).first)
    }

    @MainActor
    private func checkKeyboardAndSpeed() {
        // Space plays and pauses, unless someone is typing.
        app.typeKey(" ", modifierFlags: [])
        wait(for: "playing") { self.playPause.label == "Pause" }
        app.typeKey(" ", modifierFlags: [])
        wait(for: "paused") { self.playPause.label == "Play" }

        // ⌘F searches titles, and Space there types instead of playing.
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        wait(for: "search focused") { search.value(forKey: "hasKeyboardFocus") as? Bool == true }
        search.typeText("no such meeting")
        wait(for: "row filtered out") { !self.app.outlines["meetingList"].exists }
        XCTAssertEqual(playPause.label, "Play")
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.outlines["meetingList"].waitForExistence(timeout: 5))

        // Speed changes, and goes back so the test doesn't leave a preference behind.
        choose(speed: "2×")
        choose(speed: "1×")
    }

    /// Renaming the open meeting moves its folder and keeps playing from the same place.
    @MainActor
    private func renameWhilePlaying() throws {
        let position = app.sliders["playerPosition"]
        position.adjust(toNormalizedSliderPosition: 0.25)
        playPause.click()
        wait(for: "playing") { self.playPause.label == "Pause" }
        try rename(to: "Budget Review")
        wait(for: "still playing") { self.playPause.exists && self.playPause.label == "Pause" }
        XCTAssertGreaterThan(position.normalizedSliderPosition, 0.2)
    }

    @MainActor
    private func recordSecondMeetingAndLeaveATitleHalfTyped() {
        // The new meeting opens when it's saved.
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        stop.click()
        wait(for: "second meeting saved") { self.folders(in: self.meetings).count == 2 && self.record.exists }
        wait(for: "second meeting open") { self.title.value as? String == "Recording" }

        // Choosing another meeting keeps a half-typed title, and leaves shortcuts working.
        title.click()
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Left Unfinished")
        let firstRow = NSPredicate(format: "value BEGINSWITH %@", "Budget Review")
        app.outlines["meetingList"].staticTexts.matching(firstRow).firstMatch.click()
        wait(for: "first meeting open") { self.title.value as? String == "Budget Review" }
        wait(for: "typed title kept") {
            self.folders(in: self.meetings).contains { $0.lastPathComponent.hasSuffix(" Left Unfinished") }
        }
    }

    @MainActor
    private func checkTrash(firstMeeting: URL) {
        // Moving to the Trash removes the row and selects its neighbor.
        let moveToTrash = app.menuBars.menuItems["Move to Trash"]
        wait(for: "Move to Trash enabled") { moveToTrash.isEnabled }
        app.typeKey(.delete, modifierFlags: .command)
        wait(for: "first meeting gone") { self.folders(in: self.meetings).count == 1 }
        wait(for: "neighbor open") { self.title.value as? String == "Left Unfinished" }
        XCTAssertEqual(folders(in: trash).map(\.lastPathComponent), [firstMeeting.lastPathComponent])

        // Trashing the last meeting leaves an empty library and no player.
        app.typeKey(.delete, modifierFlags: .command)
        wait(for: "library empty") { self.folders(in: self.meetings).isEmpty }
        wait(for: "list empty") { !self.app.outlines["meetingList"].exists }
        XCTAssertFalse(playPause.exists)
    }

    @MainActor
    private func choose(speed: String) {
        let picker = app.popUpButtons["playerSpeed"]
        picker.click()
        app.menuItems[speed].click()
        wait(for: "speed \(speed)") { picker.value as? String == speed }
    }
}
