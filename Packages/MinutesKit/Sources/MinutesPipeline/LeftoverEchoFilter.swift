// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesAudio
import MinutesStorage

/// Removes mic words an engine heard in what echo removal left behind, which would otherwise read as
/// things the user said. They're garbled rather than copies of the other track, so this goes by
/// loudness: a phrase is dropped only if it's barely above the room's background while the system
/// track is playing. One audible word keeps its whole phrase. See docs/NOTES.md for the measurements.
enum LeftoverEchoFilter {
    /// A phrase's loudest word must clear the room's background by this much to count as speech.
    /// Measured: leftover echo reached 6.4 dB, and the quietest real phrase 14.7 dB.
    static let marginDecibels: Float = 10
    /// Words further apart than this are separate phrases.
    private static let phraseGap = 0.5
    /// Quieter than this, the system track isn't making anything that could echo.
    private static let systemSoundDecibels: Float = -60
    /// Sound stays in the room for a moment after the system track stops playing it.
    private static let echoTail = 0.5

    /// With no sound on the mic track to compare against, it keeps everything.
    static func keeping(_ words: [TranscriptWord], mic: LevelTimeline, system: LevelTimeline) -> [TranscriptWord] {
        guard let noiseFloor = mic.noiseFloor else {
            return words
        }
        let threshold = noiseFloor + marginDecibels
        return phrases(in: words).flatMap { phrase in
            isLeftoverEcho(phrase, threshold: threshold, mic: mic, system: system) ? [] : phrase
        }
    }

    private static func phrases(in words: [TranscriptWord]) -> [[TranscriptWord]] {
        var phrases: [[TranscriptWord]] = []
        for word in words {
            if let previous = phrases.last?.last, word.start - previous.end <= phraseGap {
                phrases[phrases.count - 1].append(word)
            } else {
                phrases.append([word])
            }
        }
        return phrases
    }

    private static func isLeftoverEcho(
        _ phrase: [TranscriptWord],
        threshold: Float,
        mic: LevelTimeline,
        system: LevelTimeline,
    ) -> Bool {
        guard let first = phrase.first, let last = phrase.last else {
            return false
        }
        let levels = phrase.map { mic.level(from: $0.start, to: $0.end) }
        // A word outside the measured audio can't be judged, so it isn't called echo.
        let isQuiet = levels.allSatisfy { level in
            level.map { $0 < threshold } ?? false
        }
        guard isQuiet else {
            return false
        }
        return system.loudest(from: first.start - echoTail, to: last.end) ?? -.infinity > systemSoundDecibels
    }
}

private extension LevelTimeline {
    /// The loudest block from one moment to another, or `nil` if that's outside the track.
    func loudest(from start: Double, to end: Double) -> Float? {
        let first = max(0, Int(start / Self.blockSeconds))
        let last = min(decibels.count, max(first + 1, Int((end / Self.blockSeconds).rounded(.up))))
        return first < last ? decibels[first ..< last].max() : nil
    }
}
