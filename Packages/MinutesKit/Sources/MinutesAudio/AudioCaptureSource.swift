// SPDX-License-Identifier: GPL-3.0-or-later

/// Something that happened to a running source, safe to show or log.
public enum CaptureEvent: Equatable, Sendable {
    /// The source rebuilt itself after a device change. Device names only.
    case restarted(deviceName: String)
    /// A chosen input device went away, so the source moved to the default.
    case fellBackToDefaultInput(missingDeviceUID: String)
    /// The source couldn't rebuild and is still retrying.
    case retrying
    case failed(reason: String)
}

/// One track's audio source. The real ones are `SystemAudioTap` and `MicCapture`, and tests use fakes.
public protocol AudioCaptureSource: AnyObject, Sendable {
    /// Starts delivering to `ring`. It may block, for example on a permission prompt, so it
    /// must not be called on the main thread.
    func start(writingTo ring: AudioRing, events: @escaping @Sendable (CaptureEvent) -> Void) throws

    /// Stops delivering. Nothing writes to the ring after this returns.
    func stop()
}
