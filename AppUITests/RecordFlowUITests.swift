// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Record → stop → saved → play → rename → trash, using the app's fake audio sources, since
/// nothing can grant audio permissions to a test. Milestone 3 extends this through to the transcript.
final class RecordFlowUITests: XCTestCase {
    private var root: URL!
    private var trash: URL!
    private var app: XCUIApplication!

    private var meetings: URL {
        root.appendingPathComponent("Meetings")
    }

    private var record: XCUIElement {
        app.buttons["toolbarRecord"]
    }

    private var stop: XCUIElement {
        app.buttons["stopRecording"]
    }

    private var playPause: XCUIElement {
        app.buttons["playerPlayPause"]
    }

    private var title: XCUIElement {
        app.textFields["meetingTitleField"]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let name = "MinutesUITests-\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        trash = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-trash")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: trash)
        try? FileManager.default.removeItem(atPath: "\(root.path)-pointer.json")
    }

    @MainActor
    func testRecordThenPlayRenameAndTrash() throws {
        app = XCUIApplication()
        app.launchEnvironment["MINUTES_FAKE_AUDIO"] = "1"
        app.launchEnvironment["MINUTES_TEST_ROOT"] = root.path
        app.launchEnvironment["MINUTES_TEST_TRASH"] = trash.path
        app.launchArguments += ["-consentNoteShown", "YES"]
        app.launch()

        try recordFirstMeeting()
        checkKeyboardAndSpeed()
        let renamed = try renameWhilePlaying()
        recordSecondMeetingAndLeaveATitleHalfTyped()
        checkTrash(firstMeeting: renamed)
        app.terminate()
    }

    @MainActor
    private func recordFirstMeeting() throws {
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        // Long enough to still be playing after the rename.
        Thread.sleep(forTimeInterval: 8)
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
    private func renameWhilePlaying() throws -> URL {
        let position = app.sliders["playerPosition"]
        position.adjust(toNormalizedSliderPosition: 0.25)
        playPause.click()
        wait(for: "playing") { self.playPause.label == "Pause" }
        app.menuBars.menuItems["Rename Meeting"].click()
        wait(for: "title focused") { self.title.value(forKey: "hasKeyboardFocus") as? Bool == true }
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Budget Review\n")
        wait(for: "folder renamed") {
            self.folders(in: self.meetings).first?.lastPathComponent.hasSuffix(" Budget Review") == true
        }
        wait(for: "still playing") { self.playPause.exists && self.playPause.label == "Pause" }
        XCTAssertGreaterThan(position.normalizedSliderPosition, 0.2)

        let renamed = try XCTUnwrap(folders(in: meetings).first)
        let metadata = try String(contentsOf: renamed.appendingPathComponent("meeting.json"), encoding: .utf8)
        XCTAssertTrue(metadata.contains("\"title\" : \"Budget Review\""))
        return renamed
    }

    @MainActor
    private func recordSecondMeetingAndLeaveATitleHalfTyped() {
        // A new recording pauses playback, and the new meeting opens when it's saved.
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        wait(for: "paused by recording") { self.playPause.label == "Play" }
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

    private func folders(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    @MainActor
    private func choose(speed: String) {
        let picker = app.popUpButtons["playerSpeed"]
        picker.click()
        app.menuItems[speed].click()
        wait(for: "speed \(speed)") { picker.value as? String == speed }
    }

    @MainActor
    private func wait(for what: String, until condition: @escaping () -> Bool) {
        let finished = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        finished.expectationDescription = what
        wait(for: [finished], timeout: 10)
    }
}
