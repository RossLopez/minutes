// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Remembers where the library lives, in a small file any process can read.
public struct LibraryPointer: Sendable {
    public enum Status: Equatable, Sendable {
        case ready
        /// A chosen location that isn't there, such as an unplugged drive.
        case missing(URL)
    }

    private struct Contents: Codable {
        var rootPath: String
    }

    public static let defaultFile = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Minutes/library.json")

    public let file: URL

    public init(file: URL = LibraryPointer.defaultFile) {
        self.file = file
    }

    /// The chosen library folder, or `nil` when it's still the default.
    public var chosenRoot: URL? {
        guard let data = try? Data(contentsOf: file),
              let contents = try? JSONDecoder().decode(Contents.self, from: data)
        else {
            return nil
        }
        return URL(fileURLWithPath: contents.rootPath, isDirectory: true)
    }

    /// Where the library is expected to be, whether or not it's there right now.
    public func root(default defaultRoot: URL = MinutesLibrary.defaultRoot) -> URL {
        chosenRoot ?? defaultRoot
    }

    /// The default folder gets created when needed, but a chosen one never does, because writing
    /// to the path of an unplugged drive would put recordings where nobody would look for them.
    public func status(default defaultRoot: URL = MinutesLibrary.defaultRoot) -> Status {
        guard let chosenRoot, chosenRoot.standardizedFileURL != defaultRoot.standardizedFileURL else {
            return .ready
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: chosenRoot.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? .ready : .missing(chosenRoot)
    }

    public func setRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let contents = Contents(rootPath: root.standardizedFileURL.path)
        try JSONEncoder().encode(contents).write(to: file, options: .atomic)
    }

    /// Goes back to the default location.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return
        }
        try FileManager.default.removeItem(at: file)
    }
}
