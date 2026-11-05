// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The `~/Minutes` folder. Milestone 2 adds the rest of the library.
public struct MinutesLibrary: Sendable {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Minutes")

    public let root: URL

    public init(root: URL = MinutesLibrary.defaultRoot) {
        self.root = root
    }

    public var meetingsFolder: URL {
        root.appendingPathComponent("Meetings", isDirectory: true)
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

    /// Meetings a crash or quit left unfinished, oldest first.
    public func unfinishedMeetings() -> [(folder: MeetingFolder, metadata: MeetingMetadata)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: meetingsFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        )) ?? []
        return urls
            .map { MeetingFolder(url: $0) }
            .compactMap { folder in
                guard let metadata = try? folder.loadMetadata(), metadata.state != .complete else {
                    return nil
                }
                return (folder, metadata)
            }
            .sorted { $0.metadata.startedAt < $1.metadata.startedAt }
    }

    /// A name safe on all filesystems, like `2026-11-05 0930 Weekly sync`.
    public static func folderName(startedAt: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "\(formatter.string(from: startedAt)) \(safeName(title))"
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
}
