// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

extension RecordingController {
    func revealLastSaved() {
        guard let lastSavedFolder else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastSavedFolder])
    }
}
