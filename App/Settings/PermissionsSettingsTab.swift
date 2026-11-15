// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

struct PermissionsSettingsTab: View {
    private let model = PermissionsModel.shared

    var body: some View {
        Form {
            PermissionRows()
        }
        .formStyle(.grouped)
        .task {
            await model.refresh(includingSystemAudio: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refresh(includingSystemAudio: true)
            }
        }
    }
}
