// SPDX-License-Identifier: GPL-3.0-or-later

/// Warnings shown during a recording. They never stop it, because stopping is always manual.
public struct RecordingWarnings: Equatable, Sendable {
    public static let defaultLimitSeconds: Double = 4 * 60 * 60
    public static let lowDiskBytes: Int64 = 2_000_000_000

    public var pastLimit: Bool
    public var lowDisk: Bool

    public init(elapsedSeconds: Double, limitSeconds: Double, freeBytes: Int64?) {
        pastLimit = elapsedSeconds >= limitSeconds
        lowDisk = freeBytes.map { $0 < Self.lowDiskBytes } ?? false
    }
}
