// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    public let uid: String
    public let name: String

    public var id: String {
        uid
    }
}

public enum AudioDevices {
    /// Devices that can record, for the input picker.
    public static func inputDevices() -> [AudioInputDevice] {
        allDevices().compactMap { device in
            guard inputChannelCount(device) > 0,
                  let uid = string(device, kAudioDevicePropertyDeviceUID),
                  let name = string(device, kAudioObjectPropertyName)
            else {
                return nil
            }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    public static func defaultInputName() -> String? {
        string(defaultInputDevice(), kAudioObjectPropertyName)
    }

    public static func defaultOutputName() -> String? {
        string(defaultOutputDevice(), kAudioObjectPropertyName)
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    /// How long sound takes between the device's IO timestamps and the air, in seconds, as the
    /// device reports it. See docs/NOTES.md for how closely this matches a measurement.
    static func reportedLatency(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Double {
        var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate) == noErr, rate > 0 else {
            return 0
        }
        var streamsAddress = address(kAudioDevicePropertyStreams, scope: scope)
        var size = UInt32(0)
        AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &size)
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        if !streams.isEmpty {
            AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &size, &streams)
        }
        let stream = streams.first.map { frameValue(
            $0,
            kAudioStreamPropertyLatency,
            scope: kAudioObjectPropertyScopeGlobal,
        ) }
        return Double(frameValue(device, kAudioDevicePropertyLatency, scope: scope) + (stream ?? 0)) / rate
    }

    private static func frameValue(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
    ) -> UInt32 {
        var address = address(selector, scope: scope)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    static func deviceName(_ device: AudioObjectID) -> String {
        string(device, kAudioObjectPropertyName) ?? "Unknown device"
    }

    static func device(withUID uid: String) -> AudioObjectID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    static func currentProcessObject() throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object,
        )
        guard status == noErr, object != kAudioObjectUnknown else {
            throw CoreAudioError(operation: "translate PID to process object", status: status)
        }
        return object
    }

    private static func allDevices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    private static func inputChannelCount(_ device: AudioObjectID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment,
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

public struct CoreAudioError: Error, CustomStringConvertible, Equatable {
    public let operation: String
    public let status: OSStatus

    public var description: String {
        "\(operation) failed with status \(status)"
    }
}
