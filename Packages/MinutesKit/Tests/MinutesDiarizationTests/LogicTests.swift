// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesDiarization
import MinutesStorage
import Testing

private func word(_ start: Double, _ end: Double) -> TranscriptWord {
    TranscriptWord(text: "w", start: start, end: end)
}

private func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerTurn {
    SpeakerTurn(speaker: speaker, start: start, end: end)
}

// MARK: - Attribution

@Test func `a word goes to the speaker talking at its midpoint`() {
    let diarization = Diarization(turns: [turn("A", 0, 2), turn("B", 2, 4)])
    let result = SpeakerAttribution.attribute([word(0.2, 0.6), word(1.5, 2.3), word(1.9, 2.9)], to: diarization)
    // The second word's middle is 1.9, the third's 2.4.
    #expect(result.speakers == ["speaker-1", "speaker-1", "speaker-2"])
    #expect(result.ids == ["A": "speaker-1", "B": "speaker-2"])
}

@Test func `a word in a gap goes to the nearer turn`() {
    let diarization = Diarization(turns: [turn("A", 0, 1), turn("B", 5, 6)])
    let result = SpeakerAttribution.attribute([word(1.5, 1.7), word(3.9, 4.3)], to: diarization)
    #expect(result.speakers == ["speaker-1", "speaker-2"])
}

@Test func `words before the first turn and after the last go to them`() {
    let diarization = Diarization(turns: [turn("A", 2, 3), turn("B", 4, 5)])
    let result = SpeakerAttribution.attribute([word(0, 0.5), word(9, 9.5)], to: diarization)
    #expect(result.speakers == ["speaker-1", "speaker-2"])
}

@Test func `where turns overlap, the word goes to the one it overlaps more`() {
    let diarization = Diarization(turns: [turn("A", 0, 3), turn("B", 2.5, 6)])
    let result = SpeakerAttribution.attribute([word(2.6, 3.4)], to: diarization)
    #expect(result.speakers == ["speaker-1"])
}

@Test func `speakers are numbered by their first word, not the diarizer's names`() {
    let diarization = Diarization(turns: [turn("S3", 0, 1), turn("S1", 1, 2), turn("S2", 2, 3)])
    // Nobody says anything during S3's turn.
    let result = SpeakerAttribution.attribute([word(1.2, 1.4), word(2.2, 2.4)], to: diarization)
    #expect(result.speakers == ["speaker-1", "speaker-2"])
    #expect(result.ids == ["S1": "speaker-1", "S2": "speaker-2"])
}

@Test func `with nobody heard, the words stay with others`() {
    let result = SpeakerAttribution.attribute([word(0, 1)], to: Diarization(turns: []))
    #expect(result.speakers == [Transcript.Speaker.others])
    #expect(result.ids.isEmpty)
}

@Test func `a long meeting is attributed quickly`() {
    let turns = (0 ..< 5000).map { turn("S\($0 % 4)", Double($0) * 3, Double($0) * 3 + 2.5) }
    let words = (0 ..< 40000).map { word(Double($0) * 0.37, Double($0) * 0.37 + 0.3) }
    let started = ContinuousClock.now
    let result = SpeakerAttribution.attribute(words, to: Diarization(turns: turns))
    #expect(result.speakers.count == words.count)
    #expect(started.duration(to: .now) < .seconds(2))
}

// MARK: - Matching

private func profile(_ name: String, _ embeddings: [Float]...) -> SpeakerProfile {
    SpeakerProfile(name: name, samples: embeddings.map {
        VoiceSample(meeting: UUID(), recordedAt: Date(), seconds: 30, embedding: $0)
    })
}

/// A unit vector `degrees` away from the x axis, so its cosine with [1, 0] is cos(degrees).
private func voice(_ degrees: Double) -> [Float] {
    let radians = degrees * .pi / 180
    return [Float(cos(radians)), Float(sin(radians))]
}

@Test func `a close voice that's clearly ahead gets the name`() {
    let dana = profile("Dana", [1, 0])
    let sam = profile("Sam", [0, 1])
    let matches = VoiceMatcher.match(["speaker-1": voice(20)], against: [dana, sam])
    #expect(matches["speaker-1"] == .applied(profile: dana.id, name: "Dana"))
}

@Test func `a voice between the cutoffs is only suggested`() {
    let dana = profile("Dana", [1, 0])
    // cos(55°) is 0.57.
    let matches = VoiceMatcher.match(["speaker-1": voice(55)], against: [dana])
    #expect(matches["speaker-1"] == .suggested(profile: dana.id, name: "Dana"))
}

@Test func `a voice unlike every profile gets nothing`() {
    let matches = VoiceMatcher.match(["speaker-1": voice(70)], against: [profile("Dana", [1, 0])])
    #expect(matches.isEmpty)
}

@Test func `two profiles that both fit are only a suggestion`() {
    let dana = profile("Dana", voice(-10))
    let danna = profile("Danna", voice(10))
    let matches = VoiceMatcher.match(["speaker-1": voice(1)], against: [dana, danna])
    #expect(matches["speaker-1"] == .suggested(profile: danna.id, name: "Danna"))
}

@Test func `a profile names only the speaker it fits best`() {
    let dana = profile("Dana", [1, 0])
    let matches = VoiceMatcher.match(["speaker-1": voice(30), "speaker-2": voice(5)], against: [dana])
    #expect(matches == ["speaker-2": .applied(profile: dana.id, name: "Dana")])
}

@Test func `the closest of a profile's meetings counts`() {
    let dana = profile("Dana", voice(80), voice(5))
    #expect(VoiceMatcher.match(["speaker-1": voice(0)], against: [dana])["speaker-1"]
        == .applied(profile: dana.id, name: "Dana"))
}

@Test func `a declined profile isn't offered again`() {
    let dana = profile("Dana", [1, 0])
    let matches = VoiceMatcher.match(["speaker-1": voice(0)], against: [dana], declined: ["speaker-1": [dana.id]])
    #expect(matches.isEmpty)
}

@Test func `embeddings of different sizes never match`() {
    #expect(VoiceMatcher.match(["speaker-1": [1, 0, 0]], against: [profile("Dana", [1, 0])]).isEmpty)
    #expect(VoiceMatcher.cosine([0, 0], [1, 0]) == -1)
}

// MARK: - Carrying names over

private func line(_ speaker: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: speaker, words: [TranscriptWord(text: "w", start: start, end: end)])
}

@Test func `names follow the speakers they overlap in time`() {
    let old = [line("speaker-1", 0, 10), line("speaker-2", 10, 20), line("me", 20, 22)]
    let names: [String: MeetingMetadata.Speaker] = [
        "speaker-1": .init(name: "Dana"),
        "speaker-2": .init(name: "Sam"),
        "me": .init(name: "Ross"),
    ]
    // The new run numbers them the other way round and moves the edges a little.
    let new = [line("speaker-2", 0, 9), line("speaker-1", 9, 20), line("me", 20, 22)]
    let carried = NameCarryOver.carry(from: old, names: names, to: new)
    #expect(carried.mapValues(\.name) == ["speaker-2": "Dana", "speaker-1": "Sam", "me": "Ross"])
}

@Test func `a speaker mostly heard elsewhere doesn't inherit a name`() {
    let old = [line("speaker-1", 0, 10)]
    let new = [line("speaker-1", 8, 20)]
    #expect(NameCarryOver.carry(from: old, names: ["speaker-1": .init(name: "Dana")], to: new).isEmpty)
}

@Test func `one old name goes to one new speaker`() {
    let old = [line("speaker-1", 0, 20)]
    let new = [line("speaker-1", 0, 8), line("speaker-2", 8, 20)]
    let carried = NameCarryOver.carry(from: old, names: ["speaker-1": .init(name: "Dana")], to: new)
    #expect(carried.mapValues(\.name) == ["speaker-2": "Dana"])
}
