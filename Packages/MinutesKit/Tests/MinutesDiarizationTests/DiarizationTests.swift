// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesDiarization
import Testing

@Test func `speakers are listed in the order they first talk`() {
    let diarization = Diarization(turns: [
        SpeakerTurn(speaker: "S2", start: 0, end: 1),
        SpeakerTurn(speaker: "S1", start: 1, end: 2),
        SpeakerTurn(speaker: "S2", start: 2, end: 3),
    ])
    #expect(diarization.speakers == ["S2", "S1"])
}

@Test func `a turn never ends before it starts`() {
    #expect(SpeakerTurn(speaker: "S1", start: 5, end: 4).duration == 0)
}

@Test func `a diarization survives a round trip through JSON`() throws {
    let diarization = Diarization(
        turns: [SpeakerTurn(speaker: "S1", start: 0.5, end: 2.25)],
        embeddings: ["S1": [0.25, -0.5, 1]],
    )
    let data = try JSONEncoder().encode(diarization)
    #expect(try JSONDecoder().decode(Diarization.self, from: data) == diarization)
}
