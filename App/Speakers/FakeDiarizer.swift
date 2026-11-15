// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
    import Foundation
    import MinutesDiarization

    /// Stands in for the real diarizer in UI tests, turned on by `MINUTES_FAKE_DIARIZATION`.
    /// It hears one voice until a minute and one second in, and another after, which splits the
    /// fake transcription engine's system line in two.
    struct FakeDiarizer: SpeakerDiarizer {
        let id = "fake-diarizer"
        let modelName = "Fake"
        let downloadSizeBytes: Int64 = 22_000_000

        func modelStatus() async -> DiarizationModelStatus {
            .installed
        }

        func installModel(progress _: @escaping @Sendable (Double) -> Void) async throws {}

        func removeModel() async throws {}

        func diarize(
            audio _: URL,
            workFolder _: URL,
            progress _: @escaping @Sendable (Double) -> Void,
        ) async throws -> Diarization {
            if DemoContent.isOn {
                return Self.demoDiarization()
            }
            return Diarization(
                turns: [SpeakerTurn(speaker: "A", start: 0, end: 61), SpeakerTurn(speaker: "B", start: 61, end: 7200)],
                embeddings: ["A": [1, 0], "B": [0, 1]],
            )
        }

        /// The demo meeting's other voices, laid out as the fake transcription lays out their words.
        private static func demoDiarization() -> Diarization {
            let turns = DemoContent.layout().filter { $0.code != "me" }.map { line in
                SpeakerTurn(speaker: line.code, start: line.start, end: line.end)
            }
            let codes = Set(turns.map(\.speaker))
            return Diarization(turns: turns, embeddings: Dictionary(uniqueKeysWithValues: codes.map { code in
                (code, DemoContent.voice(code))
            }))
        }

        func embedding(audio _: URL, spans _: [ClosedRange<Double>], workFolder _: URL) async throws -> [Float] {
            [1, 0]
        }
    }
#endif
