// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct MainWindowView: View {
    @AppStorage(RecordingPreferences.consentNoteShownKey) private var consentNoteShown = false
    @FocusState private var isSearchFocused: Bool
    private let controller = RecordingController.shared
    private let store = LibraryStore.shared

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { store.sidebarItem }, set: { store.sidebarItem = $0 ?? .allMeetings })
    }

    private var isPlayerShowing: Bool {
        store.sidebarItem == .allMeetings && store.player.loadedFolder != nil
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
                Section {
                    Button {
                        store.openTrash()
                    } label: {
                        Label("Recently Deleted", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Open the Trash in Finder")
                    .accessibilityIdentifier("recentlyDeleted")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            Group {
                switch store.sidebarItem {
                case .allMeetings:
                    MeetingListView(store: store)
                case .chat:
                    ContentUnavailableView(
                        "No Chats",
                        systemImage: SidebarItem.chat.systemImage,
                        description: Text("Chat about your past meetings arrives in Milestone 8."),
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if store.sidebarItem == .allMeetings, let entry = store.selectedEntry {
                MeetingDetailView(store: store, entry: entry)
                    .id(entry.id)
            } else {
                ContentUnavailableView("No Meeting Selected", systemImage: "doc.text")
            }
        }
        .searchable(
            text: Binding(get: { store.searchText }, set: { store.searchText = $0 }),
            placement: .sidebar,
            prompt: "Search Titles",
        )
        .searchFocused($isSearchFocused)
        .onChange(of: isSearchFocused) {
            store.isEditingSearch = isSearchFocused
        }
        .onChange(of: store.searchRequests) {
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await store.refresh()
            }
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
            // Keeps the recording status above the player.
            .padding(.bottom, isPlayerShowing ? 104 : 0)
        }
        .alert("Recording Consent", isPresented: .constant(!consentNoteShown)) {
            Button("OK") {
                consentNoteShown = true
            }
        } message: {
            Text(
                """
                Some places require everyone's consent to record a conversation. Getting it is up to you. \
                If you turn on Remember voices, the same goes for saving the voices of the people you name.
                """,
            )
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
