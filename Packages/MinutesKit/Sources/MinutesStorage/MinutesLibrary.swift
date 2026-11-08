// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// The `~/Minutes` folder. Its files are the source of truth for everything the app shows.
public struct MinutesLibrary: Sendable {
    public enum LibraryError: Error, Equatable {
        case emptyTitle
        /// Only finished meetings can be renamed, because capture and encoding write to their folders.
        case meetingNotFinished
        /// Saving through this version's model would drop fields it doesn't know.
        case newerFileFormat
        case unreadableMetadata
    }

    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Minutes")

    public let root: URL

    public init(root: URL = MinutesLibrary.defaultRoot) {
        self.root = root
    }

    public var meetingsFolder: URL {
        root.appendingPathComponent("Meetings", isDirectory: true)
    }

    public var templatesFolder: URL {
        root.appendingPathComponent("Templates", isDirectory: true)
    }

    public var modelsFolder: URL {
        root.appendingPathComponent("Models", isDirectory: true)
    }

    /// The rebuildable index and logs.
    public var internalFolder: URL {
        root.appendingPathComponent(".minutes", isDirectory: true)
    }

    public var vocabularyFile: URL {
        root.appendingPathComponent("Vocabulary.txt")
    }

    /// An empty list if there's no file yet. Throws if the file exists but isn't text, so nothing overwrites it.
    public func loadVocabulary() throws -> [VocabularyEntry] {
        guard FileManager.default.fileExists(atPath: vocabularyFile.path) else {
            return []
        }
        return try Vocabulary.parse(String(contentsOf: vocabularyFile, encoding: .utf8))
    }

    public func saveVocabulary(_ entries: [VocabularyEntry]) throws {
        try Data(Vocabulary.render(entries).utf8).write(to: vocabularyFile, options: .atomic)
    }

    /// Creates the library's folders. Safe to call every launch.
    public func prepareLayout() throws {
        let logs = internalFolder.appendingPathComponent("logs", isDirectory: true)
        for folder in [meetingsFolder, templatesFolder, modelsFolder, logs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Models can be downloaded again and the index rebuilt, so backups shouldn't carry them.
        for var folder in [modelsFolder, internalFolder] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        }
    }

    /// Creates `Meetings/<date time> <title>/audio/`, adding a number if that name is taken.
    public func createMeetingFolder(startedAt: Date, title: String) throws -> MeetingFolder {
        let base = Self.folderName(startedAt: startedAt, title: title)
        for attempt in 1 ... 1000 {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            let url = meetingsFolder.appendingPathComponent(name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            let folder = MeetingFolder(url: url)
            try FileManager.default.createDirectory(at: folder.audioFolder, withIntermediateDirectories: true)
            return folder
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Every folder in `Meetings/`, newest first.
    public func meetings() -> [MeetingEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: meetingsFolder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
        )) ?? []
        return urls
            .compactMap { url -> MeetingEntry? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else {
                    return nil
                }
                let folder = MeetingFolder(url: url)
                let metadata = try? folder.loadMetadata()
                return MeetingEntry(
                    folder: folder,
                    metadata: metadata,
                    date: metadata?.startedAt
                        ?? Self.date(fromFolderName: url.lastPathComponent)
                        ?? values.creationDate
                        ?? .distantPast,
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// Meetings a crash or quit left unfinished, oldest first. Files from a newer version are
    /// left alone, because finishing one means rewriting its `meeting.json`.
    public func unfinishedMeetings() -> [(folder: MeetingFolder, metadata: MeetingMetadata)] {
        meetings()
            .compactMap { entry in
                guard let metadata = entry.metadata, metadata.state != .complete, !metadata.isNewerThanThisApp else {
                    return nil
                }
                return (entry.folder, metadata)
            }
            .sorted { $0.metadata.startedAt < $1.metadata.startedAt }
    }

    /// Changes a finished meeting's title and renames its folder to match. Returns the folder's new location.
    public func rename(_ folder: MeetingFolder, to newTitle: String) throws -> MeetingFolder {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw LibraryError.emptyTitle
        }
        return try MeetingFolder.metadataLock.withLock {
            try renameLocked(folder, to: title)
        }
    }

    private func renameLocked(_ folder: MeetingFolder, to title: String) throws -> MeetingFolder {
        guard var metadata = try? folder.loadMetadata() else {
            throw LibraryError.unreadableMetadata
        }
        guard !metadata.isNewerThanThisApp else {
            throw LibraryError.newerFileFormat
        }
        guard metadata.state == .complete else {
            throw LibraryError.meetingNotFinished
        }

        let oldTitle = metadata.title
        let destination = try availableURL(renaming: folder, title: title, startedAt: metadata.startedAt)
        metadata.title = title
        try folder.save(metadata)
        do {
            try Self.moveFolder(from: folder.url, to: destination)
        } catch {
            metadata.title = oldTitle
            try? folder.save(metadata)
            throw error
        }
        let renamed = MeetingFolder(url: destination)
        // The readable transcript starts with the title. If this fails, the transcript itself is still right.
        if let transcript = try? renamed.loadTranscript() {
            try? renamed.save(transcript, title: title, startedAt: metadata.startedAt)
        }
        return renamed
    }

    /// Moves a meeting's folder to the Trash. Returns where it landed, if the system says.
    @discardableResult
    public func moveToTrash(_ folder: MeetingFolder) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: folder.url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// A name safe on all filesystems, like `2026-11-05 0930 Weekly sync`.
    public static func folderName(startedAt: Date, title: String) -> String {
        "\(datePrefix(startedAt)) \(safeName(title))"
    }

    static func datePrefix(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: date)
    }

    /// Reads the date back out of a name like `2026-11-05 0930 Weekly Sync`.
    static func date(fromFolderName name: String) -> Date? {
        guard let prefix = name.prefixMatch(of: /\d{4}-\d{2}-\d{2} \d{4}/)?.0 else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.date(from: String(prefix))
    }

    /// `2026-11-05 0930 Weekly Sync` becomes `Weekly Sync`.
    static func nameWithoutDate(_ name: String) -> String {
        guard let rest = name.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{4} (.+)/)?.1 else {
            return name
        }
        return String(rest)
    }

    static func safeName(_ title: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = title
            .components(separatedBy: unsafe)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let limited = String(cleaned.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return limited.isEmpty ? "Untitled" : limited
    }

    /// The name a renamed folder should have, keeping its current date prefix. A meeting's
    /// `startedAt` can format differently after a time zone change, and the folder shouldn't shift.
    private func availableURL(renaming folder: MeetingFolder, title: String, startedAt: Date) throws -> URL {
        let current = folder.url.lastPathComponent
        let prefixMatch = current.wholeMatch(of: /(\d{4}-\d{2}-\d{2} \d{4}) .*/)?.1
        let prefix = prefixMatch.map(String.init) ?? Self.datePrefix(startedAt)
        let base = "\(prefix) \(Self.safeName(title))"
        let parent = folder.url.deletingLastPathComponent()
        for attempt in 1 ... 1000 {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            let url = parent.appendingPathComponent(name, isDirectory: true)
            if name == current || !FileManager.default.fileExists(atPath: url.path)
                || Self.isSameItem(url, folder.url)
            {
                return url
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// True when a path differing only by case leads to the same folder on a case-insensitive disk.
    private static func isSameItem(_ first: URL, _ second: URL) -> Bool {
        func identifier(_ url: URL) -> NSObject? {
            let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
            return values?.fileResourceIdentifier as? NSObject
        }
        guard let first = identifier(first), let second = identifier(second) else {
            return false
        }
        return first.isEqual(second)
    }

    private static func moveFolder(from source: URL, to destination: URL) throws {
        guard source.lastPathComponent != destination.lastPathComponent else {
            return
        }
        guard isSameItem(source, destination) else {
            try FileManager.default.moveItem(at: source, to: destination)
            return
        }
        // `moveItem` can refuse a change of case, seeing the destination as already there.
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
