// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct MainWindowView: View {
    @State private var selection: SidebarItem? = .allMeetings
    @AppStorage(RecordingPreferences.consentNoteShownKey) private var consentNoteShown = false
    private let controller = RecordingController.shared

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
                RecordToolbarButton(controller: controller)
            }
        }
        .overlay(alignment: .bottom) {
            Group {
                if controller.isRecording {
                    RecordingHUD(controller: controller)
                } else if controller.phase == .saving || controller.lastSavedFolder != nil || !controller.notices
                    .isEmpty
                {
                    RecordingStatusBanner(controller: controller)
                }
            }
            .padding(16)
        }
        .alert("Recording Consent", isPresented: .constant(!consentNoteShown)) {
            Button("OK") {
                consentNoteShown = true
            }
        } message: {
            Text("Some places require everyone's consent to record a conversation. Getting it is up to you.")
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

private struct RecordToolbarButton: View {
    let controller: RecordingController

    var body: some View {
        if controller.isRecording {
            Button("Stop", systemImage: "stop.fill") {
                controller.stopRecording()
            }
            .tint(.red)
            .accessibilityIdentifier("toolbarStop")
        } else {
            Button("Record", systemImage: "record.circle") {
                controller.startRecording()
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canToggle)
            .accessibilityIdentifier("toolbarRecord")
        }
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
