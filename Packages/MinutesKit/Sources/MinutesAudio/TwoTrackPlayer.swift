// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation

public struct PlaybackState: Equatable, Sendable {
    public var isPlaying = false
    public var currentTime = 0.0
    public var duration = 0.0

    public init(isPlaying: Bool = false, currentTime: Double = 0, duration: Double = 0) {
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
    }
}

/// What the app needs from a player, so the UI can be tested with a fake.
@MainActor
public protocol MeetingPlayback: AnyObject {
    var state: PlaybackState { get }
    var availableTracks: Set<PlaybackTrack> { get }
    var onStateChange: (@MainActor (PlaybackState) -> Void)? { get set }

    func play()
    func pause()
    func seek(to seconds: Double)
    func setSpeed(_ speed: Float)
    func setMuted(_ muted: Bool, track: PlaybackTrack)
    /// Stops playback and releases the audio files. The player can't be used after this.
    func close()
}

@MainActor
public final class TwoTrackPlayer: MeetingPlayback {
    private static let updateInterval = CMTime(value: 1, timescale: 10)
    /// Within this much of the end, Play starts over instead of ending again at once.
    private static let endTolerance = 0.05

    public private(set) var state: PlaybackState
    public var onStateChange: (@MainActor (PlaybackState) -> Void)?

    private let composition: PlaybackComposition
    private let item: AVPlayerItem
    private let player: AVPlayer
    private var muted: Set<PlaybackTrack> = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    public static func load(mic: URL?, system: URL?) async throws -> TwoTrackPlayer {
        try await TwoTrackPlayer(composition: PlaybackComposition.make(mic: mic, system: system))
    }

    private init(composition: PlaybackComposition) {
        self.composition = composition
        item = AVPlayerItem(asset: composition.asset)
        // Keeps pitch at faster speeds, and it's the algorithm Apple describes for speech.
        item.audioTimePitchAlgorithm = .timeDomain
        item.audioMix = composition.audioMix(muted: [])
        player = AVPlayer(playerItem: item)
        // The files are local, so there's nothing to wait for.
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        state = PlaybackState(duration: composition.asset.duration.seconds)
        observe()
    }

    public var availableTracks: Set<PlaybackTrack> {
        composition.availableTracks
    }

    public func play() {
        if state.currentTime >= state.duration - Self.endTolerance {
            seek(to: 0)
        }
        player.play()
        publish()
    }

    public func pause() {
        player.pause()
        publish()
    }

    public func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), state.duration)
        // Zero tolerance, so the place clicked is the place heard.
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 48000),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
        )
        state.currentTime = clamped
        onStateChange?(state)
    }

    public func setSpeed(_ speed: Float) {
        player.defaultRate = speed
        if player.timeControlStatus != .paused {
            player.rate = speed
        }
    }

    public func setMuted(_ isMuted: Bool, track: PlaybackTrack) {
        if isMuted {
            muted.insert(track)
        } else {
            muted.remove(track)
        }
        item.audioMix = composition.audioMix(muted: muted)
    }

    public func close() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation = nil
        onStateChange = nil
        player.replaceCurrentItem(with: nil)
    }

    private func observe() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.updateInterval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publish()
            }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in
                self?.publish()
            }
        }
    }

    private func publish() {
        let time = player.currentTime().seconds
        let next = PlaybackState(
            isPlaying: player.timeControlStatus != .paused,
            currentTime: time.isFinite ? min(max(time, 0), state.duration) : state.currentTime,
            duration: state.duration,
        )
        guard next != state else {
            return
        }
        state = next
        onStateChange?(next)
    }
}
