// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One folder in `Meetings/`. A folder Minutes can't read stays in the list, so it never seems lost.
public struct MeetingEntry: Identifiable, Equatable, Sendable {
    public let folder: MeetingFolder
    /// `nil` when `meeting.json` is missing or broken.
    public let metadata: MeetingMetadata?
    /// When the meeting began. If `meeting.json` can't be read, the date in the folder's name.
    public let date: Date

    public init(folder: MeetingFolder, metadata: MeetingMetadata?, date: Date) {
        self.folder = folder
        self.metadata = metadata
        self.date = date
    }

    /// The folder, because copying a meeting in Finder duplicates the ID in its `meeting.json`.
    public var id: URL {
        folder.url
    }

    public var title: String {
        metadata?.title ?? MinutesLibrary.nameWithoutDate(folder.url.lastPathComponent)
    }

    /// Rename only finished meetings, and only in a format this version fully understands.
    public var canRename: Bool {
        guard let metadata else {
            return false
        }
        return metadata.state == .complete && !metadata.isNewerThanThisApp
    }

    public func matches(search: String) -> Bool {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || title.localizedStandardContains(trimmed)
    }
}
