// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import Foundation
import os

/// Captures everything the Mac plays except Minutes' own sounds.
public final class SystemAudioTap: AudioCaptureSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "system-tap")
    private static let retryDelay = DispatchTimeInterval.seconds(1)

    private let queue = DispatchQueue(label: "io.github.rosslopez.minutes.system-tap", qos: .userInitiated)

    // Used only on `queue`.
    private var device: TapDevice?
    private var ring: AudioRing?
    private var events: (@Sendable (CaptureEvent) -> Void)?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    public init() {}

    public func start(writingTo ring: AudioRing, events: @escaping @Sendable (CaptureEvent) -> Void) throws {
        try queue.sync {
            self.ring = ring
            self.events = events
            try build()
            running = true
            addOutputListener()
        }
    }

    public func stop() {
        queue.sync {
            running = false
            removeOutputListener()
            device?.stop()
            device = nil
            ring = nil
            events = nil
        }
    }

    private func build() throws {
        guard let ring else {
            return
        }
        let exclude = try AudioDevices.currentProcessObject()
        let tap = TapDevice(description: CATapDescription(monoGlobalTapButExcludeProcesses: [exclude]))
        // The tap sees audio before the output device plays it.
        let output = AudioDevices.defaultOutputDevice()
        ring.setTimeOffset(seconds: AudioDevices.reportedLatency(of: output, scope: kAudioObjectPropertyScopeOutput))
        try tap.start(writingTo: ring)
        device = tap
    }

    private func addOutputListener() {
        var address = AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuild()
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        outputListener = listener
    }

    private func removeOutputListener() {
        guard let outputListener else {
            return
        }
        var address = AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
        self.outputListener = nil
    }

    /// Always called on `queue`. The file keeps going, and the timeline turns the time away into a logged gap.
    private func rebuild() {
        guard running else {
            return
        }
        device?.stop()
        device = nil
        do {
            try build()
            let name = AudioDevices.deviceName(AudioDevices.defaultOutputDevice())
            Self.logger.info("Rebuilt system tap after output change")
            events?(.restarted(deviceName: name))
        } catch {
            Self.logger.error("System tap rebuild failed: \(String(describing: error), privacy: .public)")
            events?(.retrying)
            queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.retryIfNeeded()
            }
        }
    }

    private func retryIfNeeded() {
        if running, device == nil {
            rebuild()
        }
    }
}
