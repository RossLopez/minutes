// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import MinutesSearch
import SwiftUI

struct MainWindowView: View {
    @AppStorage(RecordingPreferences.consentNoteShownKey) private var consentNoteShown = false
    @AppStorage(FirstRunView.completedKey) private var firstRunCompleted = false
    /// UI tests walk through the first run without touching this Mac's settings.
    @State private var showsTestFirstRun = FirstRunView.isForcedForTesting
    @FocusState private var isSearchFocused: Bool
    private let controller = RecordingController.shared
    private let store = LibraryStore.shared

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { store.sidebarItem }, set: { store.sidebarItem = $0 ?? .allMeetings })
    }

    private var hasBuiltInModel: Bool {
        ModelCatalog.all.contains { SummaryCenter.shared.states[$0.id].map { $0 != .notInstalled } ?? false }
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
                    ChatListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if store.sidebarItem == .chat {
                ChatDetailView()
            } else if let entry = store.selectedEntry {
                MeetingDetailView(store: store, entry: entry)
                    .id(entry.id)
            } else {
                ContentUnavailableView("No Meeting Selected", systemImage: "doc.text")
            }
        }
        .searchable(
            text: Binding(get: { store.searchText }, set: { store.searchText = $0 }),
            placement: .sidebar,
            prompt: "Search",
        )
        .searchFocused($isSearchFocused)
        .onChange(of: isSearchFocused) {
            store.isEditingSearch = isSearchFocused
        }
        .onChange(of: store.searchRequests) {
            isSearchFocused = true
        }
        .onOpenURL { url in
            // minutes://meeting/<id>?t=…, from a saved chat opened in another app.
            if let link = MeetingLink(url: url) {
                store.open(link)
            }
        }
        .sheet(item: Binding(get: { store.exportRequest }, set: { store.exportRequest = $0 })) { entry in
            ExportSheet(entry: entry)
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
            // Keeps the recording status above the player and a chat's question bar.
            .padding(.bottom, (isPlayerShowing ? 104 : 0) + (store.chatInputHeights.values.max() ?? 0))
        }
        .sheet(isPresented: .constant(!firstRunCompleted || showsTestFirstRun)) {
            FirstRunView(steps: FirstRunView.steps(
                consentShown: consentNoteShown && !showsTestFirstRun,
                hasModel: hasBuiltInModel && !showsTestFirstRun,
            )) {
                if showsTestFirstRun {
                    showsTestFirstRun = false
                } else {
                    consentNoteShown = true
                    firstRunCompleted = true
                }
            }
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
