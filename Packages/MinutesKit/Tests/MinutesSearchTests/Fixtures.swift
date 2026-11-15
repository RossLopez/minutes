// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// A library in a temporary folder, with meetings written as Minutes writes them.
struct FixtureLibrary {
    let library: MinutesLibrary

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesSearchTests-\(UUID())")
        library = MinutesLibrary(root: root)
        try library.prepareLayout()
        try FileManager.default.createDirectory(at: library.meetingsFolder, withIntermediateDirectories: true)
    }

    var indexFile: URL {
        library.internalFolder.appendingPathComponent("index.sqlite")
    }

    /// A finished meeting. Each line is `speaker|start|text`.
    @discardableResult
    func addMeeting(
        _ title: String,
        on date: Date = Date(timeIntervalSince1970: 1_800_000_000),
        lines: [String] = [],
        summary: String? = nil,
        notes: String? = nil,
        names: [String: String] = [:],
    ) throws -> (folder: MeetingFolder, metadata: MeetingMetadata) {
        let folder = try library.createMeetingFolder(startedAt: date, title: title)
        var metadata = MeetingMetadata(title: title, startedAt: date, state: .complete, audioFormat: "aac",
                                       voiceProcessing: false)
        metadata.durationSeconds = 600
        if !names.isEmpty {
            metadata.speakers = names.mapValues { MeetingMetadata.Speaker(name: $0) }
        }
        try folder.save(metadata)
        if !lines.isEmpty {
            let segments = lines.map { line in
                let parts = line.split(separator: "|", maxSplits: 2).map(String.init)
                let start = Double(parts[1]) ?? 0
                let words = parts[2].split(separator: " ").enumerated().map { index, word in
                    TranscriptWord(text: String(word), start: start + Double(index) * 0.3,
                                   end: start + Double(index) * 0.3 + 0.25)
                }
                return TranscriptSegment(speaker: parts[0], words: words)
            }
            try folder.save(Transcript(engine: "fake", model: "fake", segments: segments), for: metadata)
        }
        if let summary {
            try summary.write(to: folder.summaryFile, atomically: true, encoding: .utf8)
        }
        if let notes {
            let lineCount = NoteTimeline.lines(of: notes).count
            try folder.saveNotes(MeetingNotes(text: notes, times: (0 ..< lineCount).map { Double($0 * 60) }))
        }
        return (folder, metadata)
    }
}

/// `count` words of filler, numbered so no two runs match each other.
func filler(_ count: Int, tag: String = "word") -> String {
    (1 ... count).map { "\(tag)\($0)" }.joined(separator: " ")
}
