// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Record → stop → saved, using the app's fake audio sources, since nothing can grant audio
/// permissions to a test. Milestone 3 extends this through to the transcript.
final class RecordFlowUITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesUITests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testRecordThenStopSavesBothTracks() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MINUTES_FAKE_AUDIO"] = "1"
        app.launchEnvironment["MINUTES_TEST_ROOT"] = root.path
        app.launchArguments += ["-consentNoteShown", "YES"]
        app.launch()

        let record = app.buttons["toolbarRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.click()

        let stop = app.buttons["stopRecording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        // Let some audio reach the files.
        Thread.sleep(forTimeInterval: 2)
        stop.click()

        XCTAssertTrue(app.staticTexts["recordingSaved"].waitForExistence(timeout: 20))
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        app.terminate()

        let meetings = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Meetings"),
            includingPropertiesForKeys: nil,
        )
        let audio = try XCTUnwrap(meetings.first).appendingPathComponent("audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("mic-raw.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("system.m4a").path))
    }
}
