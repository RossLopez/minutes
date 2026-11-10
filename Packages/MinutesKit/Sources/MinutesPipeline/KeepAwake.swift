// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Keeps the Mac from idle-sleeping while there's work, and the app from being quit without
/// warning. A closed lid still sleeps it.
@MainActor
final class KeepAwake {
    private let reason: String
    private var activity: any NSObjectProtocol?

    init(reason: String) {
        self.reason = reason
    }

    func begin() {
        guard activity == nil else {
            return
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: reason,
        )
    }

    func end() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }
}
