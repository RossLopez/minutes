// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct MainWindowView: View {
    @State private var selection: SidebarItem? = .allMeetings

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            ContentUnavailableView(
                selection?.emptyTitle ?? SidebarItem.allMeetings.emptyTitle,
                systemImage: selection?.systemImage ?? SidebarItem.allMeetings.systemImage,
                description: Text(selection?.emptyDescription ?? SidebarItem.allMeetings.emptyDescription),
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            ContentUnavailableView("No Meeting Selected", systemImage: "doc.text")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {} label: {
                    Label("Record", systemImage: "record.circle")
                }
                .disabled(true)
                .help("Recording arrives in Milestone 1")
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

private enum SidebarItem: String, CaseIterable, Identifiable {
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

    var emptyTitle: String {
        switch self {
        case .allMeetings: "No Meetings"
        case .chat: "No Chats"
        }
    }

    var emptyDescription: String {
        switch self {
        case .allMeetings: "Meetings you record will appear here."
        case .chat: "Chat about your past meetings arrives in Milestone 8."
        }
    }
}
