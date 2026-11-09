// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import FluidAudio
import Synchronization

/// FluidAudio has one switch for network access, shared by every engine in this module. It stays
/// off except while a download the user started is running, and it's counted, so one download
/// finishing can't switch it off under another.
enum FluidNetwork {
    private static let downloads = Mutex(0)

    /// FluidAudio's debug output includes transcript text, and Minutes never logs that.
    static let configured: Void = {
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
        ModelHub.offlineMode = true
    }()

    /// Lets FluidAudio reach the network for the length of `body`.
    static func allowingDownloads<T>(_ body: () async throws -> T) async throws -> T {
        _ = configured
        downloads.withLock { count in
            count += 1
            ModelHub.offlineMode = false
        }
        defer {
            downloads.withLock { count in
                count -= 1
                if count == 0 {
                    ModelHub.offlineMode = true
                }
            }
        }
        return try await body()
    }

    static var isOffline: Bool {
        ModelHub.offlineMode
    }
}
