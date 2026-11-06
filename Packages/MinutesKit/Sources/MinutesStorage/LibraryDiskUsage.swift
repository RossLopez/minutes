// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How much disk the library uses, by the categories Settings → Storage shows.
public struct LibraryDiskUsage: Equatable, Sendable {
    public var audio: Int64 = 0
    /// Everything else in meeting folders: transcripts, notes and summaries.
    public var meetingText: Int64 = 0
    public var models: Int64 = 0
    /// The search index and logs.
    public var index: Int64 = 0
    /// Templates, vocabulary and anything else the user put in the folder.
    public var other: Int64 = 0

    public init() {}

    public var total: Int64 {
        audio + meetingText + models + index + other
    }

    /// Walks the library's files, so run it off the main thread.
    public init(library: MinutesLibrary) {
        let meetings = Self.allocatedBytes(in: library.meetingsFolder)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: library.meetingsFolder,
            includingPropertiesForKeys: nil,
        )) ?? []
        audio = folders.reduce(0) { $0 + Self.allocatedBytes(in: MeetingFolder(url: $1).audioFolder) }
        meetingText = max(0, meetings - audio)
        models = Self.allocatedBytes(in: library.modelsFolder)
        index = Self.allocatedBytes(in: library.internalFolder)
        other = max(0, Self.allocatedBytes(in: library.root) - meetings - models - index)
    }

    static func allocatedBytes(in folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
