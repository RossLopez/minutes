// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesSearch
import MinutesStorage

/// A made-up library for the README's screenshots: three meetings between fictional people, with
/// transcripts, summaries, notes and a saved chat. It's written through MinutesStorage, so it's in
/// the same format as a real library. None of it comes from a recording.
enum DemoLibrary {
    struct Line {
        let speaker: String
        let text: String

        init(_ speaker: String, _ text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    struct Meeting {
        let title: String
        let startedAt: Date
        /// By speaker ID. "me" is the name in General settings.
        let names: [String: String]
        let lines: [Line]
        let summary: String
        let notes: String
    }

    /// The name the screenshots launch with, which "me" shows as.
    static let yourName = "Robin"
    static let model = "gemma-4-12b"
    static let featuredTitle = "Website launch check-in"

    /// Writes the library into `root`. `writeAudio` writes a quiet track of the given length.
    static func write(to root: URL, writeAudio: (URL, Int) throws -> Void) throws {
        let library = MinutesLibrary(root: root)
        try library.prepareLayout()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Two hours ago, on the quarter hour, so it's always earlier today.
        let recent = Date(timeIntervalSinceNow: -7200)
        let quarter = recent.addingTimeInterval(-recent.timeIntervalSinceReferenceDate.truncatingRemainder(
            dividingBy: 900,
        ))

        let featured = websiteLaunch(startedAt: max(quarter, today))
        let (id, segments) = try write(featured, in: library, writeAudio: writeAudio)
        _ = try write(gardenClub(startedAt: today.addingTimeInterval(-86400 + 14.5 * 3600)), in: library,
                      writeAudio: writeAudio)
        _ = try write(volunteerSchedule(startedAt: today.addingTimeInterval(-4 * 86400 + 9.25 * 3600)),
                      in: library, writeAudio: writeAudio)
        try writeChat(about: featured, id: id, segments: segments, in: library)
    }

    /// Returns the meeting's ID and its transcript's segments, for the chat's sources.
    private static func write(_ meeting: Meeting, in library: MinutesLibrary,
                              writeAudio: (URL, Int) throws -> Void) throws -> (UUID, [TranscriptSegment])
    {
        let folder = try library.createMeetingFolder(startedAt: meeting.startedAt, title: meeting.title)
        let segments = timed(meeting.lines)
        let seconds = Int((segments.last?.end ?? 0).rounded(.up)) + 2

        var metadata = MeetingMetadata(
            title: meeting.title,
            startedAt: meeting.startedAt,
            state: .complete,
            audioFormat: "aac",
            voiceProcessing: false,
            inputDeviceName: "MacBook Pro Microphone",
            outputDeviceName: "MacBook Pro Speakers",
        )
        metadata.durationSeconds = Double(seconds)
        metadata.processing = ProcessingState(status: .complete, completedSteps: ProcessingStep.allCases,
                                              engine: "apple")
        metadata.speakers = meeting.names.mapValues { MeetingMetadata.Speaker(name: $0) }
        try folder.save(metadata)

        try FileManager.default.createDirectory(at: folder.audioFolder, withIntermediateDirectories: true)
        try writeAudio(folder.micAudio, seconds)
        try writeAudio(folder.systemAudio, seconds)

        let transcript = Transcript(engine: "apple", model: "en-US",
                                    createdAt: meeting.startedAt.addingTimeInterval(Double(seconds) + 40),
                                    segments: segments)
        try folder.save(transcript, for: metadata)
        try folder.saveReadableTranscript(transcript, for: metadata)

        // As a real summary records them, so nothing looks renamed since.
        let names = Dictionary(segments.map { ($0.speaker, metadata.displayName(forSpeaker: $0.speaker)) }) { $1 }
        try folder.saveSummary(meeting.summary, template: SummaryTemplateStore.defaultName, model: model,
                               names: names, at: meeting.startedAt.addingTimeInterval(Double(seconds) + 90))
        if !meeting.notes.isEmpty {
            try folder.saveNotes(MeetingNotes(text: meeting.notes))
        }
        return (metadata.id, segments)
    }

    /// Spreads each line's words out at an easy speaking pace, with a pause between speakers.
    static func timed(_ lines: [Line]) -> [TranscriptSegment] {
        var time = 1.5
        return lines.map { line in
            let words = line.text.split(separator: " ").map { word in
                let length = 0.2 + Double(word.count) * 0.04
                defer { time += length + 0.08 }
                return TranscriptWord(text: String(word), start: time, end: time + length)
            }
            time += 0.9
            return TranscriptSegment(speaker: line.speaker, words: words)
        }
    }

    private static func writeChat(about meeting: Meeting, id: UUID, segments: [TranscriptSegment],
                                  in library: MinutesLibrary) throws
    {
        func source(_ number: Int, kind: SearchChunk.Kind, segment: Int?, text: String) -> ChatSource {
            ChatSource(number: number, meetingID: id, meetingTitle: meeting.title,
                       meetingDate: meeting.startedAt, kind: kind, start: segment.map { segments[$0].start },
                       text: text)
        }
        let answer = """
        The launch moved to **Tuesday the 24th**, because nobody wanted to launch on a Friday with no \
        one around to fix problems [1]. On the Monday before, there's a soft launch: Elena will ask five \
        or six people to try the site and collect what they find [2].

        Before then, Marcus finishes the pricing page and the small-screen menu fix by Wednesday [3].
        """
        let turn = ChatTurn(
            question: "When is the website launching, and what happens before it?",
            answer: answer,
            sources: [
                source(1, kind: .transcript, segment: 10, text: segments[10].text),
                source(2, kind: .transcript, segment: 22, text: segments[22].text),
                source(3, kind: .summary, segment: nil, text: "Marcus: Finish the pricing page and the menu fix"),
            ],
        )
        let chat = ChatDocument(createdAt: Date(timeIntervalSinceNow: -1800), model: model, turns: [turn])
        let folder = library.root.appendingPathComponent("Chats", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try ChatFiles.save(chat, in: folder, replacing: nil)
    }
}
