// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A summary template: a name and the instructions the model follows.
public struct SummaryTemplate: Equatable, Sendable, Identifiable {
    public var name: String
    public var prompt: String

    public var id: String {
        name
    }

    public init(name: String, prompt: String) {
        self.name = name
        self.prompt = prompt
    }
}

/// Summary templates as Markdown files in `Templates/`, one per template. The file's name is the
/// template's name and its text is the prompt, so they can be edited outside the app.
public struct SummaryTemplateStore: Sendable {
    public enum StoreError: Error, Equatable, Sendable {
        case emptyName
        case nameTaken
        case noSuchTemplate
    }

    public static let defaultName = "Default"

    public let folder: URL
    /// What `Default.md` holds when it's first written or restored.
    public let defaultPrompt: String

    public init(folder: URL, defaultPrompt: String) {
        self.folder = folder
        self.defaultPrompt = defaultPrompt
    }

    /// Every readable template, the default first and the rest by name. Writes `Default.md` if it's
    /// missing. Files that aren't text are skipped, and never overwritten.
    public func templates() -> [SummaryTemplate] {
        try? ensureDefault()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let templates = files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> SummaryTemplate? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return nil
                }
                return SummaryTemplate(name: url.deletingPathExtension().lastPathComponent, prompt: text)
            }
        return templates.sorted { first, second in
            if (first.name == Self.defaultName) != (second.name == Self.defaultName) {
                return first.name == Self.defaultName
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    /// The named template, or the default when it's gone.
    public func template(named name: String) -> SummaryTemplate {
        templates().first { $0.name == name }
            ?? templates().first { $0.name == Self.defaultName }
            ?? SummaryTemplate(name: Self.defaultName, prompt: defaultPrompt)
    }

    public func save(_ template: SummaryTemplate) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(template.prompt.utf8).write(to: file(template.name), options: .atomic)
    }

    /// Adds a template with an unused name based on `name`, like "Standup 2". Returns its name.
    @discardableResult
    public func add(named name: String, prompt: String) throws -> String {
        let base = MinutesLibrary.safeName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        var candidate = base
        var number = 2
        while exists(candidate) {
            candidate = "\(base) \(number)"
            number += 1
        }
        try save(SummaryTemplate(name: candidate, prompt: prompt))
        return candidate
    }

    /// Returns the name it ended up with, made safe for a file.
    @discardableResult
    public func rename(_ name: String, to newName: String) throws -> String {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.emptyName
        }
        let safe = MinutesLibrary.safeName(trimmed)
        guard safe != name else {
            return name
        }
        guard exists(name) else {
            throw StoreError.noSuchTemplate
        }
        // A change of case alone is the same file on most Macs, so it's allowed through.
        guard !exists(safe) || safe.lowercased() == name.lowercased() else {
            throw StoreError.nameTaken
        }
        try FileManager.default.moveItem(at: file(name), to: file(safe))
        return safe
    }

    /// Moves the template's file to the Trash. Deleting the default brings back the original.
    public func delete(_ name: String) throws {
        guard exists(name) else {
            throw StoreError.noSuchTemplate
        }
        try FileManager.default.trashItem(at: file(name), resultingItemURL: nil)
        try? ensureDefault()
    }

    /// Puts the original default prompt back.
    public func restoreDefault() throws {
        try save(SummaryTemplate(name: Self.defaultName, prompt: defaultPrompt))
    }

    private func ensureDefault() throws {
        if !exists(Self.defaultName) {
            try restoreDefault()
        }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: file(name).path)
    }

    private func file(_ name: String) -> URL {
        folder.appendingPathComponent("\(name).md")
    }
}
