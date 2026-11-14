// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum SidebarItem: String, CaseIterable, Identifiable {
    case allMeetings
    case chat

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .allMeetings: "All Meetings"
        case .chat: "Chat"
        }
    }

    var systemImage: String {
        switch self {
        case .allMeetings: "waveform"
        case .chat: "bubble.left.and.bubble.right"
        }
    }
}
