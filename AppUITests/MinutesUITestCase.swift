// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import XCTest

/// What the UI tests share: a throwaway library, and launching the app with its fake audio and
/// transcription engine, which holds each track until `releaseFile` exists.
class MinutesUITestCase: XCTestCase {
    var root: URL!
    var trash: URL!
    var releaseFile: URL!
    var app: XCUIApplication!

    var meetings: URL {
        root.appendingPathComponent("Meetings")
    }

    @MainActor
    var record: XCUIElement {
        app.buttons["toolbarRecord"]
    }

    @MainActor
    var stop: XCUIElement {
        app.buttons["stopRecording"]
    }

    @MainActor
    var playPause: XCUIElement {
        app.buttons["playerPlayPause"]
    }

    @MainActor
    var title: XCUIElement {
        app.textFields["meetingTitleField"]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let name = "MinutesUITests-\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        trash = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-trash")
        releaseFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-release")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: trash)
        try? FileManager.default.removeItem(at: releaseFile)
        try? FileManager.default.removeItem(atPath: "\(root.path)-pointer.json")
    }

    @MainActor
    func launch(holdingTranscription: Bool = false, diarizing: Bool = false, summarizing: Bool = false,
                tab: String = "transcript")
    {
        if !holdingTranscription {
            FileManager.default.createFile(atPath: releaseFile.path, contents: nil)
        }
        app = XCUIApplication()
        app.launchEnvironment["MINUTES_FAKE_TRANSCRIPTION"] = releaseFile.path
        app.launchEnvironment["MINUTES_FAKE_AUDIO"] = "1"
        app.launchEnvironment["MINUTES_TEST_ROOT"] = root.path
        app.launchEnvironment["MINUTES_TEST_TRASH"] = trash.path
        if diarizing {
            app.launchEnvironment["MINUTES_FAKE_DIARIZATION"] = "1"
        }
        if summarizing {
            app.launchEnvironment["MINUTES_FAKE_LLM"] = "1"
        }
        // The app shares its settings with the real one, so pin the ones these tests depend on.
        app.launchArguments += ["-consentNoteShown", "YES", "-speakers.remembersVoices", "NO"]
        app.launchArguments += ["-general.yourName", "Robin", "-meeting.tab", tab]
        app.launchArguments += ["-ai.summarizeAutomatically", "YES", "-ai.defaultTemplate", "Default"]
        // Typed text arrives as typed, whatever this Mac's keyboard settings.
        app.launchArguments += ["-NSAutomaticSpellingCorrectionEnabled", "NO"]
        app.launchArguments += ["-NSAutomaticCapitalizationEnabled", "NO"]
        app.launch()
    }

    /// Two minutes of silence on both tracks, far longer than any wait in these tests.
    func seedLongMeeting() throws {
        let started = Date(timeIntervalSinceNow: -3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let folder = meetings.appendingPathComponent("\(formatter.string(from: started)) Long Meeting")
        let audio = folder.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)

        let metadata: [String: Any] = [
            "schemaVersion": 1,
            "id": UUID().uuidString,
            "title": "Long Meeting",
            "startedAt": ISO8601DateFormatter().string(from: started),
            "durationSeconds": 120,
            "state": "complete",
            "audioFormat": "aac",
            "voiceProcessing": false,
            "mic": ["gaps": []],
            "system": ["gaps": []],
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
            .write(to: folder.appendingPathComponent("meeting.json"))

        let mic = audio.appendingPathComponent("mic-raw.m4a")
        try writeSilence(to: mic, seconds: 120)
        try FileManager.default.copyItem(at: mic, to: audio.appendingPathComponent("system.m4a"))
    }

    /// The file finishes writing when `AVAudioFile` goes away at the end of this function.
    func writeSilence(to url: URL, seconds: Int) throws {
        let rate = 48000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(rate),
        ))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: 0, count: rate)
        for _ in 0 ..< seconds {
            try file.write(from: buffer)
        }
    }

    /// Renames the open meeting through the menu, and checks its folder and `meeting.json`.
    @MainActor
    func rename(to newTitle: String) throws {
        app.menuBars.menuItems["Rename Meeting"].click()
        wait(for: "title focused") { self.title.value(forKey: "hasKeyboardFocus") as? Bool == true }
        title.typeKey("a", modifierFlags: .command)
        title.typeText("\(newTitle)\n")
        wait(for: "folder renamed") {
            self.folders(in: self.meetings).first?.lastPathComponent.hasSuffix(" \(newTitle)") == true
        }
        let renamed = try XCTUnwrap(folders(in: meetings).first)
        let metadata = try String(contentsOf: renamed.appendingPathComponent("meeting.json"), encoding: .utf8)
        XCTAssertTrue(metadata.contains(newTitle))
    }

    func folders(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    @MainActor
    func wait(for what: String, until condition: @escaping () -> Bool) {
        let finished = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        finished.expectationDescription = what
        wait(for: [finished], timeout: 10)
    }
}
