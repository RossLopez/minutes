// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import CoreAudio
import MinutesAudioRT

public enum SystemAudioPermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case unknown
}

/// Finds out whether Minutes can capture system audio. macOS has no API for this.
///
/// A denied tap reports success and delivers zeros, which true silence would also do. So the probe
/// taps only our own process and plays a very quiet signal: anything but zeros proves access.
public enum SystemAudioPermissionProbe {
    /// About −90 dBFS: not audible, but never zero.
    static let probeAmplitude: Float = 0.00003
    static let listenWindow: TimeInterval = 1.0
    static let extendedListenWindow: TimeInterval = 3.0

    /// May show the system prompt the first time, and takes until it's answered.
    public static func run() async -> SystemAudioPermissionStatus {
        await withCheckedContinuation { continuation in
            // A dedicated thread, because `AudioDeviceStart` blocks on the prompt.
            Thread.detachNewThread {
                continuation.resume(returning: runBlocking())
            }
        }
    }

    /// Pure decision, separate so it can be tested.
    static func decide(frames: Int, nonZeroFrames: Int, descriptionStatus: OSStatus?) -> SystemAudioPermissionStatus {
        if nonZeroFrames > 0 {
            return .granted
        }
        if descriptionStatus == kAudioDevicePermissionsError {
            return .denied
        }
        return frames > 0 ? .denied : .unknown
    }

    private static func runBlocking() -> SystemAudioPermissionStatus {
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else {
            return .unknown
        }
        let source = mrt_make_probe_source_node(format, probeAmplitude)
        engine.attach(source)
        do {
            try engine.connectNode(source, to: engine.mainMixerNode, format: format)
            try engine.start()
        } catch {
            return .unknown
        }
        defer { engine.stop() }

        // Our process has to be playing before it can be tapped.
        Thread.sleep(forTimeInterval: 0.2)

        let ring = AudioRing(capacityFrames: 1 << 18)
        guard let process = try? AudioDevices.currentProcessObject() else {
            return .unknown
        }
        let tap = TapDevice(description: CATapDescription(monoMixdownOfProcesses: [process]))
        defer { tap.stop() }
        do {
            try tap.start(writingTo: ring)
        } catch {
            return .unknown
        }

        // Granted is known as soon as real audio arrives. Only a denial waits out the window.
        var counts = Counts()
        let start = Date()
        while Date().timeIntervalSince(start) < extendedListenWindow {
            Thread.sleep(forTimeInterval: 0.05)
            counts.drain(ring)
            if counts.nonZero > 0 {
                return .granted
            }
            if counts.frames > 0, Date().timeIntervalSince(start) >= listenWindow {
                break
            }
        }
        return decide(
            frames: counts.frames,
            nonZeroFrames: counts.nonZero,
            descriptionStatus: tap.descriptionWriteStatus(),
        )
    }

    private struct Counts {
        var frames = 0
        var nonZero = 0

        mutating func drain(_ ring: AudioRing) {
            let capacity = 32768
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            defer { scratch.deallocate() }
            var chunk = MRTChunkBox()
            while chunk.read(from: ring, into: scratch, capacity: UInt32(capacity)) {
                frames += chunk.frames
                for index in 0 ..< chunk.frames where scratch[index] != 0 {
                    nonZero += 1
                }
            }
        }
    }
}
