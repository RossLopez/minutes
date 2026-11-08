// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import Synchronization

/// Where a meeting's folder is right now. Renaming a meeting moves its folder, even in the middle of processing.
public final class MeetingLocation: Sendable {
    private let current: Mutex<MeetingFolder>

    public init(folder: MeetingFolder) {
        current = Mutex(folder)
    }

    public var folder: MeetingFolder {
        current.withLock { $0 }
    }

    /// Runs `body` while the folder can't move. Keep it short: a rename on the main thread waits for it.
    public func access<Result>(_ body: (MeetingFolder) throws -> Result) throws -> Result {
        try current.withLock { folder in
            try body(folder)
        }
    }

    /// Moves the folder, with `body` doing the move and returning the new location.
    @discardableResult
    public func move(_ body: (MeetingFolder) throws -> MeetingFolder) throws -> MeetingFolder {
        try current.withLock { folder in
            folder = try body(folder)
            return folder
        }
    }
}
