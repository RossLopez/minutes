// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesSearch
import MinutesStorage

extension LibraryStore {
    /// The index answered the search field, so more meetings may match.
    func searchResultsChanged() {
        rebuildSections()
    }

    func entry(forMeeting id: UUID) -> MeetingEntry? {
        entries.first { $0.metadata?.id == id }
    }

    /// Shows a place in a meeting: a citation, a search result, or a `minutes://` link from a
    /// saved chat. It never changes anything, and only plays when asked to from inside the app.
    /// Returns false when the meeting isn't in the library.
    @discardableResult
    func open(_ link: MeetingLink, playing: Bool = false) -> Bool {
        guard let entry = entry(forMeeting: link.meetingID) else {
            return false
        }
        sidebarItem = .allMeetings
        // A search that hides the meeting would leave nothing selected.
        if !sections.contains(where: { $0.entries.contains { $0.id == entry.id } }) {
            searchText = ""
        }
        select(entry.id, revealingMatch: false)
        show(entry, at: link, playing: playing)
        return true
    }

    /// Opening a meeting found by its text shows it where the text matched.
    func revealSearchMatch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty, let entry = selectedEntry,
              let match = SearchCenter.shared.match(for: entry)
        else {
            return
        }
        let chunk = match.hit.chunk
        show(entry, at: MeetingLink(meetingID: match.meetingID, seconds: chunk.start, kind: chunk.kind), playing: false)
    }

    private func show(_ entry: MeetingEntry, at link: MeetingLink, playing: Bool) {
        MeetingTab(showing: link.kind).choose()
        SearchCenter.shared.requestReveal(of: link.meetingID, kind: link.kind, seconds: link.seconds)
        // The summary and cleaned-up notes have no times.
        guard let seconds = link.seconds, link.kind == .transcript || link.kind == .notes,
              entry.metadata?.state == .complete, !isActive(entry)
        else {
            return
        }
        if player.loadedFolder == entry.id, player.isReady {
            if playing {
                player.play(from: seconds)
            } else {
                player.seek(to: seconds)
            }
        } else {
            player.load(entry.folder, at: seconds, playing: playing)
        }
    }
}
