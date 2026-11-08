// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import SwiftUI

/// All meetings, grouped by date.
struct MeetingListView: View {
    let store: LibraryStore

    private var selection: Binding<URL?> {
        Binding(get: { store.selection }, set: { store.select($0) })
    }

    var body: some View {
        if let missing = store.missingLocation {
            MissingLibraryView(store: store, location: missing)
        } else if store.sections.isEmpty {
            emptyState
        } else {
            List(selection: selection) {
                ForEach(store.sections) { section in
                    Section(section.period.title) {
                        ForEach(section.entries) { entry in
                            MeetingRow(entry: entry, dateText: section.period.dateText(for: entry.date))
                                .tag(entry.id)
                                .contextMenu {
                                    MeetingActions(store: store, entry: entry)
                                }
                        }
                    }
                }
            }
            .accessibilityIdentifier("meetingList")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.searchText.isEmpty {
            ContentUnavailableView(
                "No Meetings",
                systemImage: "waveform",
                description: Text("Meetings you record will appear here."),
            )
        } else {
            ContentUnavailableView.search(text: store.searchText)
        }
    }
}

private struct MeetingRow: View {
    let entry: MeetingEntry
    let dateText: String

    private var state: MeetingDisplayState {
        MeetingDisplayState(entry: entry)
    }

    private var details: String {
        [dateText, MeetingFormatting.duration(entry.metadata?.durationSeconds)]
            .compactMap(\.self)
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
                .lineLimit(2)
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let badge = state.badge {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(state == .recording ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            } else if let badge = TranscriptionCenter.shared.badge(for: entry) {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meetingRow")
    }
}

/// Offered when a chosen library folder isn't there, such as on an unplugged drive.
private struct MissingLibraryView: View {
    let store: LibraryStore
    let location: URL

    var body: some View {
        // A long path would push `ContentUnavailableView` wider than this column.
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Your Minutes Folder Can't Be Found")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(location.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(location.path)
            Text("If it's on a drive, connect the drive.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Locate…") {
                Task {
                    await store.locateLibrary()
                }
            }
            Button("Use Default Folder") {
                Task {
                    await store.useDefaultLocation()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("missingLibrary")
    }
}

/// The same actions in the row's context menu, the detail view's menu and the menu bar.
struct MeetingActions: View {
    let store: LibraryStore
    let entry: MeetingEntry

    var body: some View {
        Button("Rename") {
            store.requestRename(of: entry)
        }
        .disabled(!entry.canRename || store.isActive(entry))

        Button("Reveal in Finder") {
            store.reveal(entry)
        }

        if MeetingDisplayState(entry: entry) == .ready,
           let title = TranscriptionCenter.shared.transcribeTitle(for: entry)
        {
            Button(title) {
                TranscriptionCenter.shared.transcribe(entry)
            }
        }

        Divider()

        Button("Move to Trash") {
            Task {
                await store.moveToTrash(entry)
            }
        }
        .disabled(store.isActive(entry))
    }
}
