// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Plays the demo video's scenes in the app's demo mode, for `scripts/record-demo.sh` to record.
/// Each scene asks the script to start recording the window, waits until it has, plays, then asks
/// it to stop. Clicks and typing are logged with their times and places in the window, so a
/// video editor can draw a cursor over them. Skipped unless that script runs it.
final class DemoVideoUITests: MinutesUITestCase {
    private var signals: URL!
    private var events: [[String: Any]] = []
    private var sceneStart = Date()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MINUTES_DEMO_VIDEO"] == "1",
                          "Run scripts/record-demo.sh to record the demo video.")
        // The one folder outside its sandbox the runner may use (MinutesUITests.entitlements).
        signals = URL(fileURLWithPath: "/private/tmp/MinutesDemoVideo", isDirectory: true)
        // The script makes the folder empty before it starts the test.
        XCTAssertTrue(FileManager.default.fileExists(atPath: signals.path), "Run scripts/record-demo.sh")
    }

    @MainActor
    func testRecordDemoScenes() throws {
        try DemoLibrary.write(to: root, includingFeatured: false) { url, seconds in
            try writeSilence(to: url, seconds: seconds)
        }
        try DemoLibrary.writeVoices(to: root)
        launch(diarizing: true, summarizing: true, tab: nil, environment: [
            "MINUTES_DEMO": "1",
            "MINUTES_APPEARANCE": "light",
            "MINUTES_WINDOW_SIZE": "{1280, 720}",
            "MINUTES_FAKE_LLM_NAME": "Gemma 4 12B",
        ], arguments: ["-speakers.remembersVoices", "YES", "-ai.summarizeAutomatically", "NO"])
        let rows = app.outlines["meetingList"].descendants(matching: .any).matching(identifier: "meetingRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        // The window settles at its size and place before anything is recorded.
        pause(2)

        try scene("01-library") {
            pause(1)
            click(rows.element(boundBy: 0))
            pause(0.8)
            click(app.radioButtons["Summary"].firstMatch)
            pause(2.5)
        }
        try scene("02-recording", recordWithNotes)
        try scene("03-transcript", transcribeAndName)
        try scene("04-summary", summarize)
        try scene("05-chat", chat)
        try scene("06-search", search)
        app.terminate()
    }

    // MARK: - Scenes

    /// Starts recording and takes notes while the demo meeting plays. It ends still recording, so
    /// the next scene opens on Stop.
    @MainActor
    private func recordWithNotes() {
        pause(1)
        click(record)
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        let started = Date()
        let editor = app.textViews["notesEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        click(editor)
        let notes = DemoContent.notes.split(separator: "\n").map(String.init)
        // Spread through the meeting, near when each thing is said.
        for (note, moment) in zip(notes, [5.0, 15.0, 30.0, 37.0]) {
            pause(max(0, moment - Date().timeIntervalSince(started)))
            type(note + "\n", into: editor)
        }
        pause(max(0, DemoContent.plannedSeconds + 0.5 - Date().timeIntervalSince(started)))
    }

    /// Stops, waits for the transcript, and takes the suggestion that the third voice is Elena.
    @MainActor
    private func transcribeAndName() {
        pause(0.8)
        click(stop)
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        // The saved message stays until it's closed.
        let dismiss = app.buttons["Dismiss"].firstMatch
        if dismiss.waitForExistence(timeout: 5) {
            pause(1.5)
            click(dismiss)
        }
        let transcript = app.radioButtons["Transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        click(transcript)
        // A line is one element for accessibility, its speaker's name first.
        let lines = app.descendants(matching: .any).matching(identifier: "transcriptLine")
        let suggested = lines.matching(NSPredicate(format: "label BEGINSWITH %@", "Speaker 3 · Elena?")).firstMatch
        XCTAssertTrue(suggested.waitForExistence(timeout: 30))
        pause(2)
        // The name is at the top left of the line.
        click(suggested, at: CGVector(dx: 50, dy: 9))
        let accept = app.buttons["speakerAcceptSuggestion"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        pause(1.2)
        click(accept)
        XCTAssertTrue(lines.matching(NSPredicate(format: "label BEGINSWITH %@", "Elena")).firstMatch
            .waitForExistence(timeout: 10))
        // Clicking the name also played the line, which the video doesn't need.
        if playPause.label == "Pause" {
            pause(0.6)
            click(playPause)
        }
        pause(1.5)
        let list = app.descendants(matching: .any)["transcriptList"]
        for _ in 0 ..< 6 {
            list.scroll(byDeltaX: 0, deltaY: -60)
            pause(0.25)
        }
        pause(1.5)
    }

    @MainActor
    private func summarize() {
        pause(0.5)
        click(app.radioButtons["Summary"].firstMatch)
        let button = app.buttons["summarySummarize"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        pause(1)
        click(button)
        // Stop shows while it's written.
        let stopWriting = app.buttons["summaryStop"]
        XCTAssertTrue(stopWriting.waitForExistence(timeout: 10))
        let finished = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stopWriting)
        wait(for: [finished], timeout: 60)
        pause(1)
        // Down to the action items, at a pace to read.
        let summary = app.descendants(matching: .any)["summaryText"].firstMatch
        for _ in 0 ..< 12 {
            summary.scroll(byDeltaX: 0, deltaY: -60)
            pause(0.2)
        }
        pause(2.5)
    }

    /// Asks about the meeting, then follows the first source back into the transcript.
    @MainActor
    private func chat() {
        pause(0.5)
        click(app.outlines.staticTexts["Chat"].firstMatch)
        let newChat = app.buttons["newChatEmpty"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        pause(0.8)
        click(newChat)
        let field = app.descendants(matching: .any)["chatQuestion"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        click(field)
        type(DemoContent.chatQuestion, into: field)
        pause(0.5)
        field.typeText("\n")
        XCTAssertTrue(text("small-screen menu fix").waitForExistence(timeout: 60))
        pause(2.5)
        // A transcript source, which opens at its moment, rather than the summary.
        let source = app.buttons.matching(identifier: "chatSource")
            .matching(NSPredicate(format: "label CONTAINS %@", "· 0:")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        click(source)
        XCTAssertTrue(app.descendants(matching: .any)["transcriptList"].waitForExistence(timeout: 10))
        pause(2.5)
    }

    @MainActor
    private func search() {
        pause(0.8)
        app.typeKey("f", modifierFlags: .command)
        log(["type": "key", "keys": "cmd-f"])
        pause(0.5)
        type("redirects", into: app.searchFields.firstMatch)
        let found = app.outlines["meetingList"].staticTexts
            .matching(NSPredicate(format: "value CONTAINS[c] %@", "redirects")).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 15))
        pause(3)
    }

    // MARK: - Recording a scene

    /// Has the script record the window while `body` plays, and saves the scene's events.
    @MainActor
    private func scene(_ name: String, _ body: @MainActor () throws -> Void) throws {
        let frame = app.windows["main"].frame
        let start: [String: Any] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        try JSONSerialization.data(withJSONObject: start).write(to: signal(name, "start"))
        waitForSignal(name, "go")
        events = []
        sceneStart = Date()
        try body()
        pause(0.6)
        let record: [String: Any] = [
            "scene": name, "window": start, "duration": Date().timeIntervalSince(sceneStart), "events": events,
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: signal(name, "events.json"))
        FileManager.default.createFile(atPath: signal(name, "stop").path, contents: nil)
        waitForSignal(name, "done")
    }

    private func signal(_ scene: String, _ kind: String) -> URL {
        signals.appendingPathComponent("\(scene).\(kind)")
    }

    /// Waits up to 30 seconds, since the script's recordings take a moment to start and to save.
    private func waitForSignal(_ scene: String, _ kind: String) {
        let file = signal(scene, kind).path
        let deadline = Date(timeIntervalSinceNow: 30)
        while !FileManager.default.fileExists(atPath: file), Date() < deadline {
            pause(0.1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file), "No \(kind) from record-demo.sh for \(scene)")
    }

    private func log(_ event: [String: Any]) {
        var event = event
        event["t"] = Date().timeIntervalSince(sceneStart)
        events.append(event)
    }

    /// Clicks the middle of `element`, logging where that is in the window, in points.
    @MainActor
    private func click(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let window = app.windows["main"].frame
        let frame = element.frame
        log(["type": "click", "x": frame.midX - window.minX, "y": frame.midY - window.minY])
        element.click()
    }

    /// Clicks `offset` points from the top left of `element`.
    @MainActor
    private func click(_ element: XCUIElement, at offset: CGVector) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let window = app.windows["main"].frame
        let frame = element.frame
        log(["type": "click", "x": frame.minX + offset.dx - window.minX, "y": frame.minY + offset.dy - window.minY])
        element.coordinate(withNormalizedOffset: .zero).withOffset(offset).click()
    }

    /// Types a character at a time, at an easy pace to watch.
    @MainActor
    private func type(_ text: String, into element: XCUIElement) {
        log(["type": "typeStart", "text": text])
        for character in text {
            element.typeText(String(character))
            pause(character == " " ? 0.07 : 0.04)
        }
        log(["type": "typeEnd"])
    }

    @MainActor
    private func text(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
