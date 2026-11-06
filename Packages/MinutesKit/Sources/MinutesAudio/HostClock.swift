// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio

/// The host clock both tracks are placed against.
public enum HostClock {
    public static func nowNanos() -> UInt64 {
        AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
    }

    public static func nanos(fromHostTime hostTime: UInt64) -> UInt64 {
        AudioConvertHostTimeToNanos(hostTime)
    }

    public static func hostTime(fromNanos nanos: UInt64) -> UInt64 {
        AudioConvertNanosToHostTime(nanos)
    }
}
