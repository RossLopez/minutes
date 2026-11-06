// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesAudio
import MinutesStorage
import Observation
import os

/// The state behind the player bar, for whichever meeting is open.
@MainActor @Observable
final class PlayerModel {
    static let speeds: [Float] = [1, 1.25, 1.5, 1.75, 2]

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "player")
    private static let speedKey = "player.speed"

    private(set) var state = PlaybackState()
    private(set) var availableTracks: Set<PlaybackTrack> = []
    private(set) var loadedFolder: URL?
    private(set) var isReady = false
    private(set) var loadFailed = false
    private(set) var mutedTracks: Set<PlaybackTrack> = []
    private(set) var speed: Float

    @ObservationIgnored private var player: any MeetingPlayback?
    /// So a slow load can't replace a meeting opened after it.
    @ObservationIgnored private var generation = 0

    init() {
        let saved = UserDefaults.standard.float(forKey: Self.speedKey)
        speed = Self.speeds.contains(saved) ? saved : 1
    }

    /// Opens a meeting's audio, optionally continuing from a position.
    func load(_ folder: MeetingFolder, at position: Double = 0, playing: Bool = false) {
        unload()
        loadedFolder = folder.url
        let current = generation
        Task {
            do {
                let loaded = try await TwoTrackPlayer.load(
                    mic: folder.playbackMicAudio,
                    system: folder.systemAudio,
                )
                guard current == generation else {
                    loaded.close()
                    return
                }
                attach(loaded, at: position, playing: playing)
            } catch {
                guard current == generation else {
                    return
                }
                Self.logger.error("Opening audio failed: \(String(describing: error), privacy: .public)")
                loadFailed = true
            }
        }
    }

    /// Stops playback and lets go of the audio files.
    func unload() {
        generation += 1
        player?.close()
        player = nil
        loadedFolder = nil
        isReady = false
        loadFailed = false
        state = PlaybackState()
        availableTracks = []
        mutedTracks = []
    }

    func togglePlayPause() {
        if state.isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
    }

    func pause() {
        player?.pause()
    }

    func seek(to seconds: Double) {
        player?.seek(to: seconds)
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        UserDefaults.standard.set(newSpeed, forKey: Self.speedKey)
        player?.setSpeed(newSpeed)
    }

    func setMuted(_ muted: Bool, track: PlaybackTrack) {
        if muted {
            mutedTracks.insert(track)
        } else {
            mutedTracks.remove(track)
        }
        player?.setMuted(muted, track: track)
    }

    private func attach(_ loaded: any MeetingPlayback, at position: Double, playing: Bool) {
        player = loaded
        availableTracks = loaded.availableTracks
        state = loaded.state
        isReady = true
        loaded.setSpeed(speed)
        loaded.onStateChange = { [weak self] newState in
            self?.state = newState
        }
        if position > 0 {
            loaded.seek(to: position)
        }
        if playing {
            loaded.play()
        }
    }
}
