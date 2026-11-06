// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Moves the whole library to a new parent folder. The original stays intact until the new copy
/// has been checked.
public enum LibraryMover {
    public enum MoveError: Error, Equatable {
        case insideCurrentLibrary
        case alreadyExists(URL)
        /// Folders that get synced to iCloud, which would take meetings off the Mac.
        case syncedFolder
        case notEnoughSpace(needed: Int64, available: Int64)
        case verificationFailed
    }

    public struct Result: Equatable, Sendable {
        public let newRoot: URL
        /// Whether the old folder is gone. If it couldn't go to the Trash, it's left in place.
        public let removedOldFolder: Bool
    }

    /// Throws if the library can't move into `parent`, without changing anything.
    public static func validate(
        from root: URL,
        toParent parent: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
    ) throws {
        let parentPath = parent.resolvingSymlinksInPath().path + "/"
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        guard !parentPath.hasPrefix(rootPath) else {
            throw MoveError.insideCurrentLibrary
        }
        for synced in ["Documents", "Library/Mobile Documents"] {
            let syncedPath = home.appendingPathComponent(synced).resolvingSymlinksInPath().path + "/"
            guard !parentPath.hasPrefix(syncedPath) else {
                throw MoveError.syncedFolder
            }
        }
        let destination = destination(parent: parent, root: root)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MoveError.alreadyExists(destination)
        }
    }

    /// Moves the library, then calls `commit` with its new location before the old folder goes
    /// away. If `commit` throws, the new copy is removed and the original stays where it was.
    public static func move(
        from root: URL,
        toParent parent: URL,
        commit: (URL) throws -> Void,
    ) throws -> Result {
        try move(from: root, toParent: parent, commit: commit, operations: .standard)
    }

    static func move(
        from root: URL,
        toParent parent: URL,
        commit: (URL) throws -> Void,
        operations: Operations,
    ) throws -> Result {
        try validate(from: root, toParent: parent)
        let destination = destination(parent: parent, root: root)
        if operations.sameVolume(root, parent) {
            try FileManager.default.moveItem(at: root, to: destination)
            do {
                try commit(destination)
            } catch {
                try? FileManager.default.moveItem(at: destination, to: root)
                throw error
            }
            return Result(newRoot: destination, removedOldFolder: true)
        }

        try checkSpace(for: root, on: parent)
        let temporary = parent.appendingPathComponent(".\(root.lastPathComponent).moving-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: root, to: temporary)
            try operations.verify(root, temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        do {
            try commit(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // The Trash rather than deleting, so nothing is lost if the new drive later fails.
        return Result(newRoot: destination, removedOldFolder: operations.disposeOfOriginal(root))
    }

    /// The steps tests need to replace, since a test has only one volume and shouldn't fill the Trash.
    struct Operations {
        var sameVolume: (URL, URL) -> Bool
        var verify: (URL, URL) throws -> Void
        var disposeOfOriginal: (URL) -> Bool

        static var standard: Operations {
            Operations(
                sameVolume: LibraryMover.sameVolume,
                verify: LibraryMover.verifyCopy,
                disposeOfOriginal: { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) != nil },
            )
        }
    }

    static func destination(parent: URL, root: URL) -> URL {
        parent.appendingPathComponent(root.lastPathComponent, isDirectory: true)
    }

    /// Every file in `original` must exist in `copy` with the same size, and the reverse.
    static func verifyCopy(original: URL, copy: URL) throws {
        guard try fileSizes(in: original) == fileSizes(in: copy) else {
            throw MoveError.verificationFailed
        }
    }

    private static func fileSizes(in folder: URL) throws -> [String: Int] {
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            throw MoveError.verificationFailed
        }
        var sizes: [String: Int] = [:]
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else {
                continue
            }
            let path = url.resolvingSymlinksInPath().path
            sizes[path.replacingOccurrences(of: prefix, with: "")] = values.fileSize ?? 0
        }
        return sizes
    }

    private static func sameVolume(_ first: URL, _ second: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey])
            return values?.volumeIdentifier as? NSObject
        }
        guard let first = volume(first), let second = volume(second) else {
            return false
        }
        return first.isEqual(second)
    }

    private static func checkSpace(for root: URL, on parent: URL) throws {
        let needed = LibraryDiskUsage.allocatedBytes(in: root)
        let values = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= needed else {
            throw MoveError.notEnoughSpace(needed: needed, available: available)
        }
    }
}
