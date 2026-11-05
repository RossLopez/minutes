// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import Foundation
import MinutesAudioRT

/// A process tap attached to a private aggregate device holding nothing else, which delivers
/// to a ring through the C IOProc. Shared by the recording tap and the permission probe.
final class TapDevice {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var ring: AudioRing?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let formatQueue = DispatchQueue(label: "io.github.rosslopez.minutes.tap-format")
    private let description: CATapDescription

    init(description: CATapDescription) {
        self.description = description
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.uuid = UUID()
        description.name = "Minutes"
    }

    deinit {
        stop()
    }

    /// May block until the system audio permission prompt is answered.
    func start(writingTo ring: AudioRing) throws {
        self.ring = ring

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        try check(status, "create process tap")

        guard let tapUID = AudioDevices.string(tapID, kAudioTapPropertyUID) else {
            throw CoreAudioError(operation: "read tap UID", status: kAudioHardwareUnspecifiedError)
        }
        try ring.setSampleRate(sampleRate())
        addFormatListener()

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Minutes",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID],
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        try check(status, "create aggregate device")

        status = AudioDeviceCreateIOProcID(
            aggregateID,
            mrt_tap_ioproc,
            UnsafeMutableRawPointer(ring.raw),
            &procID,
        )
        try check(status, "create IOProc")

        status = AudioDeviceStart(aggregateID, procID)
        try check(status, "start aggregate device")
    }

    /// The community-reported permission signal: `kAudioDevicePermissionsError` when denied.
    func descriptionWriteStatus() -> OSStatus {
        var address = AudioDevices.address(kAudioTapPropertyDescription)
        var reference: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(description)
        return AudioObjectSetPropertyData(
            tapID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UnsafeRawPointer>.size),
            &reference,
        )
    }

    func sampleRate() throws -> Double {
        var address = AudioDevices.address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        try check(status, "read tap format")
        return format.mSampleRate
    }

    /// The tap follows the output device's rate, which can change while it runs.
    private func addFormatListener() {
        var address = AudioDevices.address(kAudioTapPropertyFormat)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let rate = try? sampleRate() else {
                return
            }
            ring?.setSampleRate(rate)
        }
        if AudioObjectAddPropertyListenerBlock(tapID, &address, formatQueue, listener) == noErr {
            formatListener = listener
        }
    }

    func stop() {
        if let formatListener, tapID != kAudioObjectUnknown {
            var address = AudioDevices.address(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tapID, &address, formatQueue, formatListener)
        }
        formatListener = nil
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID {
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        ring = nil
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw CoreAudioError(operation: operation, status: status)
        }
    }
}
