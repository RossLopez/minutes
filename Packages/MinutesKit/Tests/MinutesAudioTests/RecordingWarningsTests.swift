// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
@testable import MinutesAudio
import Testing

@Test func `the time warning starts at the limit`() {
    let limit = RecordingWarnings.defaultLimitSeconds
    #expect(!RecordingWarnings(elapsedSeconds: limit - 1, limitSeconds: limit, freeBytes: nil).pastLimit)
    #expect(RecordingWarnings(elapsedSeconds: limit, limitSeconds: limit, freeBytes: nil).pastLimit)
}

@Test func `the disk warning starts under 2 GB`() {
    let threshold = RecordingWarnings.lowDiskBytes
    #expect(RecordingWarnings(elapsedSeconds: 0, limitSeconds: 60, freeBytes: threshold - 1).lowDisk)
    #expect(!RecordingWarnings(elapsedSeconds: 0, limitSeconds: 60, freeBytes: threshold).lowDisk)
}

@Test func `unknown free space doesn't warn`() {
    #expect(!RecordingWarnings(elapsedSeconds: 0, limitSeconds: 60, freeBytes: nil).lowDisk)
}

@Test func `any non-zero audio from our own tap means granted`() {
    #expect(SystemAudioPermissionProbe.decide(frames: 48000, nonZeroFrames: 1, descriptionStatus: noErr) == .granted)
    #expect(SystemAudioPermissionProbe.decide(frames: 48000, nonZeroFrames: 1, descriptionStatus: nil) == .granted)
}

@Test func `frames of pure zeros mean denied`() {
    #expect(SystemAudioPermissionProbe.decide(frames: 48000, nonZeroFrames: 0, descriptionStatus: noErr) == .denied)
}

@Test func `the permissions error means denied even with no frames`() {
    let status = OSStatus(kAudioDevicePermissionsError)
    #expect(SystemAudioPermissionProbe.decide(frames: 0, nonZeroFrames: 0, descriptionStatus: status) == .denied)
}

@Test func `no frames and no error can't tell`() {
    #expect(SystemAudioPermissionProbe.decide(frames: 0, nonZeroFrames: 0, descriptionStatus: noErr) == .unknown)
    #expect(SystemAudioPermissionProbe.decide(frames: 0, nonZeroFrames: 0, descriptionStatus: nil) == .unknown)
}
