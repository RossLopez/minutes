// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private func source(notes: String? = "budget fri", cleaned: String? = nil) -> MeetingExporter.Source {
    var metadata = MeetingMetadata(
        title: "Budget Review",
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        state: .complete,
        audioFormat: "aac",
        voiceProcessing: false,
    )
    metadata.durationSeconds = 3720
    metadata.speakers = ["speaker-1": MeetingMetadata.Speaker(name: "Dana")]
    func segment(_ speaker: String, _ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, words: [TranscriptWord(text: text, start: start, end: start + 1)])
    }
    let transcript = Transcript(engine: "fake", model: "fake", segments: [
        segment("me", 3, "Let's start."),
        segment("me", 5, "Budget first."),
        segment("speaker-1", 724, "Numbers by **Friday**."),
    ])
    return MeetingExporter.Source(
        metadata: metadata,
        transcript: transcript,
        summary: "## Overview\nThe [budget](https://example.com) is **late**.\n",
        notes: notes,
        cleanedNotes: cleaned,
    )
}

private func export(_ source: MeetingExporter.Source, _ contents: MeetingExporter.Contents,
                    _ format: MeetingExporter.Format = .markdown) -> String
{
    // Foundation puts a narrow no-break space before AM.
    MeetingExporter.export(source, contents: contents, format: format,
                           locale: Locale(identifier: "en_US"), timeZone: .gmt)
        .replacingOccurrences(of: "\u{202F}", with: " ")
}

@Test func `a meeting exports as Markdown with every section`() {
    #expect(export(source(), .everything) == """
    # Budget Review

    January 15, 2027 at 8:00 AM · 1 hr 2 min
    People: Me, Dana

    ## Summary

    ### Overview
    The [budget](https://example.com) is **late**.

    ## Notes

    budget fri

    ## Transcript

    **[0:03] Me:** Let's start. Budget first.

    **[12:04] Dana:** Numbers by **Friday**.

    """)
}

@Test func `cleaned-up notes come first, and the typed ones only when asked`() {
    let both = source(notes: "budget fri", cleaned: "- Budget by Friday")
    let cleanedOnly = export(both, .notes)
    #expect(cleanedOnly.contains("## Notes\n\n- Budget by Friday"))
    #expect(!cleanedOnly.contains("budget fri"))
    #expect(export(both, [.notes, .typedNotes]).contains("## Notes as Typed\n\nbudget fri"))
    // With nothing cleaned up, the typed notes are the notes, once.
    #expect(export(source(), [.notes, .typedNotes]).components(separatedBy: "budget fri").count == 2)
}

@Test func `missing sections are left out`() {
    let text = export(source(notes: nil), [.notes, .summary])
    #expect(!text.contains("## Notes"))
    #expect(text.contains("## Summary"))
}

@Test func `plain text has the same sections without Markdown`() {
    let text = export(source(), .everything, .plainText)
    #expect(text.hasPrefix("Budget Review\n\nJanuary 15, 2027"))
    #expect(text.contains("\nOverview\nThe budget is late.\n"))
    #expect(text.contains("[12:04] Dana: Numbers by Friday."))
    #expect(!text.contains("#"))
    #expect(!text.contains("**"))
}

@Test func `durations read as minutes and hours`() {
    #expect(MeetingExporter.duration(20) == "1 min")
    #expect(MeetingExporter.duration(1500) == "25 min")
    #expect(MeetingExporter.duration(7200) == "2 hr 0 min")
}
