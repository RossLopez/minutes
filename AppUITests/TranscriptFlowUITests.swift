// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// From a stopped recording to a transcript, with the fake engine holding each track until told to go on.
final class TranscriptFlowUITests: MinutesUITestCase {
    @MainActor
    private var transcriptProgress: XCUIElement {
        app.descendants(matching: .any)["transcriptProgress"]
    }

    @MainActor
    private var transcriptLines: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "transcriptLine")
    }

    @MainActor
    func testRecordThroughToTranscript() throws {
        launch(holdingTranscription: true)
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        stop.click()

        // Transcribing starts by itself, and the meeting can be renamed along the way.
        XCTAssertTrue(transcriptProgress.waitForExistence(timeout: 20))
        try rename(to: "Budget Review")
        XCTAssertTrue(transcriptProgress.waitForExistence(timeout: 10))

        // Cancelling stays cancelled until someone resumes it.
        app.buttons["transcriptCancel"].click()
        let resume = app.buttons["transcriptResume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.click()
        XCTAssertTrue(transcriptProgress.waitForExistence(timeout: 10))

        // The finished files land in the meeting's new folder, with the work in progress gone.
        FileManager.default.createFile(atPath: releaseFile.path, contents: nil)
        wait(for: "two lines") { self.transcriptLines.count == 2 }
        let folder = try XCTUnwrap(folders(in: meetings).first)
        XCTAssertTrue(folder.lastPathComponent.hasSuffix(" Budget Review"))
        let readable = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(readable.contains("Sounds good to me."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio/mic.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".processing").path))
        app.terminate()
    }

    /// A meeting from before transcripts existed offers to make one, and its lines play when clicked.
    @MainActor
    func testClickingALinePlaysFromThatMoment() throws {
        try seedLongMeeting()
        launch()
        let row = NSPredicate(format: "value BEGINSWITH %@", "Long Meeting")
        let longMeeting = app.outlines["meetingList"].staticTexts.matching(row).firstMatch
        XCTAssertTrue(longMeeting.waitForExistence(timeout: 10))
        longMeeting.click()
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        wait(for: "player ready") { self.playPause.isEnabled }

        let transcribe = app.buttons["transcriptTranscribe"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 10))
        transcribe.click()
        wait(for: "two lines") { self.transcriptLines.count == 2 }

        // The second line starts a minute into a two-minute meeting.
        transcriptLines.element(boundBy: 1).click()
        wait(for: "playing") { self.playPause.label == "Pause" }
        let position = app.sliders["playerPosition"]
        wait(for: "moved to the line") { position.normalizedSliderPosition > 0.45 }

        // Arrow keys move through the lines.
        app.typeKey(.upArrow, modifierFlags: [])
        wait(for: "moved to the first line") { position.normalizedSliderPosition < 0.2 }

        // Space still plays and pauses with the transcript in focus.
        app.typeKey(" ", modifierFlags: [])
        wait(for: "paused") { self.playPause.label == "Play" }
        app.terminate()
    }
}
