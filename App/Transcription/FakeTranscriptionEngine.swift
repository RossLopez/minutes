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
            if DemoContent.isOn {
                return try await demoWords(isSystem: audio.lastPathComponent == "system.m4a", progress: progress)
            }
            progress(0.5)
            while !FileManager.default.fileExists(atPath: releaseFile.path) {
                try await Task.sleep(for: .milliseconds(50))
            }
            // One line per track, with enough words between them to summarize.
            return audio.lastPathComponent == "system.m4a"
                ? Self.words("Sounds good to me. I will send the updated numbers on Thursday.", from: 60)
                : Self.words("Let's start the review. We need to agree the budget before Friday.", from: 10)
        }

        /// The demo meeting's words for one track, after a few seconds of progress to watch.
        private func demoWords(isSystem: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
            -> [TranscriptWord]
        {
            for step in 1 ... 12 {
                try await Task.sleep(for: .milliseconds(200))
                progress(Double(step) / 12)
            }
            return DemoContent.layout()
                .filter { ($0.code == "me") != isSystem }
                .flatMap(\.words)
                .map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) }
        }

        private static func words(_ line: String, from start: Double) -> [TranscriptWord] {
            line.split(separator: " ").map(String.init).enumerated().map { index, text in
                let wordStart = start + Double(index) * 0.5
                return TranscriptWord(text: text, start: wordStart, end: wordStart + 0.4)
            }
        }
    }
#endif
