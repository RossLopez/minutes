// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation

public enum PlaybackTrack: String, CaseIterable, Sendable {
    case mic
    case system
}

public enum PlaybackError: Error, Equatable {
    case noAudio
}

/// A meeting's tracks as one playable item, which keeps them in sync. Both files already share a
/// timeline, because capture pads each one from the start of the recording.
@MainActor
public struct PlaybackComposition {
    public let asset: AVComposition
    private let tracks: [PlaybackTrack: AVCompositionTrack]

    /// Skips a track that's missing or unreadable, so one bad file doesn't lose the other.
    /// Throws `PlaybackError.noAudio` only if neither track can play.
    public static func make(mic: URL?, system: URL?) async throws -> PlaybackComposition {
        let composition = AVMutableComposition()
        var tracks: [PlaybackTrack: AVCompositionTrack] = [:]
        for (track, url) in [(PlaybackTrack.mic, mic), (.system, system)] {
            guard let url, let added = await add(url, to: composition) else {
                continue
            }
            tracks[track] = added
        }
        guard !tracks.isEmpty else {
            throw PlaybackError.noAudio
        }
        return PlaybackComposition(asset: composition, tracks: tracks)
    }

    public var availableTracks: Set<PlaybackTrack> {
        Set(tracks.keys)
    }

    /// A mix that silences the given tracks.
    public func audioMix(muted: Set<PlaybackTrack>) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track, compositionTrack in
            let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
            parameters.setVolume(muted.contains(track) ? 0 : 1, at: .zero)
            return parameters
        }
        return mix
    }

    private static func add(_ url: URL, to composition: AVMutableComposition) async -> AVCompositionTrack? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let asset = AVURLAsset(url: url)
        guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await source.load(.timeRange),
              let added = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid,
              )
        else {
            return nil
        }
        guard (try? added.insertTimeRange(range, of: source, at: .zero)) != nil else {
            composition.removeTrack(added)
            return nil
        }
        return added
    }
}
