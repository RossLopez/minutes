// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
    import Foundation
    import MinutesStorage
    import MinutesTranscription

    /// Stands in for a real engine in UI tests. It holds each track until `releaseFile` exists,
    /// so a test can look at the progress for as long as it needs, however slow the machine is.
    struct FakeTranscriptionEngine: TranscriptionEngine {
        let id: String
        let releaseFile: URL

        let modelName = "Fake"
        let downloadSizeBytes: Int64? = nil
        let canRemoveModel = false

        func modelStatus() async -> TranscriptionModelStatus {
            .installed
        }

        func installModel(progress _: @escaping @Sendable (Double) -> Void) async throws {}

        func removeModel() async throws {}

        func transcribe(
            audio: URL,
            vocabulary _: [VocabularyEntry],
            workFolder _: URL,
            progress: @escaping @Sendable (Double) -> Void,
        ) async throws -> [TranscriptWord] {
            progress(0.5)
            while !FileManager.default.fileExists(atPath: releaseFile.path) {
                try await Task.sleep(for: .milliseconds(50))
            }
            return audio.lastPathComponent == "system.m4a"
                ? Self.words(["Sounds", "good", "to", "me."], from: 60)
                : Self.words(["Let's", "start", "the", "review."], from: 10)
        }

        private static func words(_ texts: [String], from start: Double) -> [TranscriptWord] {
            texts.enumerated().map { index, text in
                let wordStart = start + Double(index) * 0.5
                return TranscriptWord(text: text, start: wordStart, end: wordStart + 0.4)
            }
        }
    }
#endif
