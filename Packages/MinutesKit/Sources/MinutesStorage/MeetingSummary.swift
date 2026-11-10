// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public extension MeetingMetadata {
    /// The `summary` block in `meeting.json`. The summary's text is in `summary.md`.
    struct Summary: Codable, Equatable, Sendable {
        public var status: Status
        /// The template `summary.md` was written with, by name.
        public var template: String
        /// The template the next summary is to use, when it's not `template`.
        public var requestedTemplate: String?
        /// Written for the user, with no meeting content.
        public var failure: String?
        /// The model that wrote `summary.md`.
        public var model: String?
        public var createdAt: Date?
        /// The name each speaker had when `summary.md` was written, so later renames can follow.
        public var names: [String: String]?
        /// Speakers were renamed after the summary was written, and their names replaced in it.
        public var namesChanged: Bool?

        public init(status: Status, template: String) {
            self.status = status
            self.template = template
        }

        /// The template a new summary uses.
        public var nextTemplate: String {
            requestedTemplate ?? template
        }
    }
}

public extension MeetingMetadata.Summary {
    enum Status: String, Codable, Sendable {
        /// Waiting or under way. Found like this at launch, it starts again.
        case queued
        case complete
        /// Stopped by the user. Stays stopped until they ask again.
        case stopped
        case failed
        /// The chosen model isn't installed.
        case waitingForModel
    }
}

public extension MeetingFolder {
    var summaryFile: URL {
        url.appendingPathComponent("summary.md")
    }

    /// Older summaries, kept whenever a new one replaces them.
    var summariesFolder: URL {
        url.appendingPathComponent("summaries", isDirectory: true)
    }

    func loadSummary() -> String? {
        try? String(contentsOf: summaryFile, encoding: .utf8)
    }

    /// Newest first.
    func previousSummaries() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: summariesFolder,
            includingPropertiesForKeys: nil,
        )) ?? []
        return files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Writes a new `summary.md`, moving the one it replaces into `summaries/`.
    @discardableResult
    func saveSummary(
        _ text: String,
        template: String,
        model: String,
        names: [String: String],
        at date: Date = Date(),
    ) throws -> MeetingMetadata {
        try Self.metadataLock.withLock {
            var metadata = try loadMetadata()
            guard !metadata.isNewerThanThisApp else {
                throw FolderError.newerFileFormat
            }
            if FileManager.default.fileExists(atPath: summaryFile.path) {
                try keepPrevious(metadata.summary)
            }
            try Data((text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
                .write(to: summaryFile, options: .atomic)
            var summary = MeetingMetadata.Summary(status: .complete, template: template)
            summary.model = model
            summary.createdAt = date
            summary.names = names
            metadata.summary = summary
            // Speakers renamed while it was being written get their new names.
            followRenames(in: &metadata, present: Set(names.keys), mergedInto: [:])
            try save(metadata)
            return metadata
        }
    }

    /// Changes the summary's state, creating the block if needed. The text is left alone.
    @discardableResult
    func updateSummary(_ change: (inout MeetingMetadata.Summary?) -> Void) throws -> MeetingMetadata {
        try updateMetadata { change(&$0.summary) }
    }

    private func keepPrevious(_ summary: MeetingMetadata.Summary?) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let written = summary?.createdAt
            ?? (try? summaryFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date()
        let template = MinutesLibrary.safeName(summary?.template ?? "Summary")
        try FileManager.default.createDirectory(at: summariesFolder, withIntermediateDirectories: true)
        let stamp = formatter.string(from: written)
        var destination = summariesFolder.appendingPathComponent("\(stamp) \(template).md")
        var copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = summariesFolder.appendingPathComponent("\(stamp) \(template) \(copy).md")
            copy += 1
        }
        try FileManager.default.moveItem(at: summaryFile, to: destination)
    }

    /// After speakers change, puts their new names in `summary.md` in place of the ones it was
    /// written with. `mergedInto` says where speakers that are gone went.
    internal func followRenames(in metadata: inout MeetingMetadata, present: Set<String>,
                                mergedInto: [String: String])
    {
        guard var summary = metadata.summary, let names = summary.names,
              let text = loadSummary()
        else {
            return
        }
        var replacements: [(old: String, new: String)] = []
        var updated: [String: String] = [:]
        for (speaker, old) in names {
            guard let now = present.contains(speaker) ? speaker : mergedInto[speaker] else {
                continue
            }
            let name = metadata.displayName(forSpeaker: now)
            updated[now] = name
            if name != old {
                replacements.append((old, name))
            }
        }
        guard !replacements.isEmpty else {
            return
        }
        let replaced = Self.replacingWholeWords(replacements, in: text)
        guard (try? Data(replaced.utf8).write(to: summaryFile, options: .atomic)) != nil else {
            return
        }
        summary.names = updated
        summary.namesChanged = true
        metadata.summary = summary
    }

    /// Replaces each old name where it stands as whole words. Done in two passes, so swapping two
    /// names doesn't turn both into one.
    internal static func replacingWholeWords(_ replacements: [(old: String, new: String)], in text: String) -> String {
        var result = text
        let markers = replacements.indices.map { "\u{E000}\($0)\u{E001}" }
        for (index, replacement) in replacements.enumerated() {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: replacement.old)
                + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: markers[index]),
            )
        }
        for (index, replacement) in replacements.enumerated() {
            result = result.replacingOccurrences(of: markers[index], with: replacement.new)
        }
        return result
    }
}
