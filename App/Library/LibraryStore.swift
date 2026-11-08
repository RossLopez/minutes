// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesStorage
import Observation
import os

/// The library as the app sees it: where it lives, what's in it, and what's selected. It always
/// comes from the files, so changes made in Finder appear the next time the app becomes active.
@MainActor @Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "library")

    private(set) var library: MinutesLibrary {
        didSet {
            currentLibrary.set(library)
        }
    }

    private(set) var entries: [MeetingEntry] = []
    private(set) var sections: [MeetingSection] = []
    private(set) var selection: URL?
    /// Set when the chosen library folder can't be found.
    private(set) var missingLocation: URL?
    private(set) var isMovingLibrary = false
    /// Goes up when a menu command asks the open meeting's title field to take focus.
    private(set) var renameRequests = 0
    var sidebarItem = SidebarItem.allMeetings
    /// Goes up when ⌘F asks the search field to take focus.
    private(set) var searchRequests = 0
    var isEditingTitle = false
    var isEditingSearch = false
    var searchText = "" {
        didSet {
            rebuildSections()
        }
    }

    let player = PlayerModel()
    let currentLibrary: CurrentLibrary

    @ObservationIgnored private let pointer: LibraryPointer
    @ObservationIgnored private let defaultRoot: URL
    @ObservationIgnored private let trashFolderForTests: URL?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var beingTrashed: Set<URL> = []

    private init() {
        var defaultRoot = MinutesLibrary.defaultRoot
        var pointer = LibraryPointer()
        var trashFolderForTests: URL?
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if let root = environment["MINUTES_TEST_ROOT"] {
                defaultRoot = URL(fileURLWithPath: root, isDirectory: true)
                pointer = LibraryPointer(file: URL(fileURLWithPath: "\(root)-pointer.json"))
            }
            trashFolderForTests = environment["MINUTES_TEST_TRASH"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #endif
        self.defaultRoot = defaultRoot
        self.pointer = pointer
        self.trashFolderForTests = trashFolderForTests
        let library = MinutesLibrary(root: pointer.root(default: defaultRoot))
        self.library = library
        currentLibrary = CurrentLibrary(library)
    }

    var selectedEntry: MeetingEntry? {
        entries.first { $0.id == selection }
    }

    /// Keeps ⌘⌫ and Space away from the meeting and player while someone is typing.
    var isEditingText: Bool {
        isEditingTitle || isEditingSearch
    }

    var isUsingDefaultLocation: Bool {
        library.root.standardizedFileURL == defaultRoot.standardizedFileURL
    }

    var canActOnSelection: Bool {
        guard let selectedEntry else {
            return false
        }
        return !isActive(selectedEntry)
    }

    /// Whether a recording is writing to this meeting right now.
    func isActive(_ entry: MeetingEntry) -> Bool {
        RecordingController.shared.activeFolder == entry.id
    }

    // MARK: - Reading

    /// Checks the library is there and creates its folders. Safe to call any time.
    func prepare() {
        switch pointer.status(default: defaultRoot) {
        case .ready:
            missingLocation = nil
            library = MinutesLibrary(root: pointer.root(default: defaultRoot))
            do {
                try library.prepareLayout()
            } catch {
                Self.logger.error("Preparing the library failed: \(String(describing: error), privacy: .public)")
            }
        case let .missing(url):
            missingLocation = url
            // Its folder is out of reach, so Reveal in Finder wouldn't work.
            RecordingController.shared.dismissSavedBanner()
        }
    }

    /// Reads the folder again. Only the newest of overlapping refreshes is kept.
    func refresh(selecting newSelection: URL? = nil) async {
        prepare()
        scanGeneration += 1
        let current = scanGeneration
        let library = library
        let found = await Task.detached { library.meetings() }.value
        guard current == scanGeneration else {
            return
        }
        entries = missingLocation == nil ? found : []
        rebuildSections()
        if let newSelection {
            sidebarItem = .allMeetings
            selection = newSelection
        } else if selectedEntry == nil {
            selection = nil
        }
        syncPlayer()
    }

    func select(_ url: URL?) {
        guard url != selection else {
            return
        }
        selection = url
        syncPlayer()
    }

    private func rebuildSections() {
        let matching = entries.filter { $0.matches(search: searchText) }
        sections = MeetingGrouping.sections(for: matching, now: Date())
    }

    /// Only a finished meeting that nothing is writing to has audio to open.
    private func syncPlayer() {
        guard let entry = selectedEntry, entry.metadata?.state == .complete, !isActive(entry) else {
            player.unload()
            return
        }
        if player.loadedFolder != entry.id {
            player.load(entry.folder)
        }
    }

    // MARK: - Changing meetings

    func requestSearch() {
        sidebarItem = .allMeetings
        searchRequests += 1
    }

    func requestRename(of entry: MeetingEntry) {
        select(entry.id)
        renameRequests += 1
    }

    func rename(_ entry: MeetingEntry, to title: String) async {
        // A title field can commit twice as it goes away, the second time with the old folder.
        guard entry.canRename, !isActive(entry), title != entry.title,
              FileManager.default.fileExists(atPath: entry.id.path)
        else {
            return
        }
        let wasPlayerOpen = player.loadedFolder == entry.id
        let position = player.state
        do {
            // Through the queue, so a job running on this meeting follows its folder.
            let library = library
            let renamed = try TranscriptionCenter.shared.queue.move(entry.id) { try library.rename($0, to: title) }
            RecordingController.shared.folderMoved(from: entry.id, to: renamed.url)
            if selection == entry.id {
                selection = renamed.url
            }
            if wasPlayerOpen {
                player.load(renamed, at: position.currentTime, playing: position.isPlaying)
            }
            await refresh()
        } catch MinutesLibrary.LibraryError.emptyTitle {
            // Leaving the field empty just keeps the old title.
        } catch {
            Self.logger.error("Rename failed: \(String(describing: error), privacy: .public)")
            RecordingAlerts.show(
                title: "Minutes Couldn't Rename This Meeting",
                message: "Its files are unchanged. Check that the folder isn't open elsewhere, then try again.",
            )
        }
    }

    func moveToTrash(_ entry: MeetingEntry) async {
        guard !isActive(entry), beingTrashed.insert(entry.id).inserted else {
            return
        }
        defer {
            beingTrashed.remove(entry.id)
        }
        let neighbor = neighbor(of: entry)
        if player.loadedFolder == entry.id {
            player.unload()
        }
        let queue = TranscriptionCenter.shared.queue
        let wasQueued = queue.activity?.folder == entry.id || queue.isWaiting(entry.id)
        await queue.remove(entry.id)
        do {
            if let trashFolderForTests {
                try FileManager.default.createDirectory(at: trashFolderForTests, withIntermediateDirectories: true)
                try FileManager.default.moveItem(
                    at: entry.id,
                    to: trashFolderForTests.appendingPathComponent(entry.id.lastPathComponent),
                )
            } else {
                try library.moveToTrash(entry.folder)
            }
            RecordingController.shared.folderGone(entry.id)
            entries.removeAll { $0.id == entry.id }
            rebuildSections()
            if selection == entry.id {
                selection = neighbor
            }
            await refresh()
        } catch {
            Self.logger.error("Moving to Trash failed: \(String(describing: error), privacy: .public)")
            syncPlayer()
            if wasQueued {
                queue.enqueue(entry.id)
            }
            RecordingAlerts.show(
                title: "Minutes Couldn't Move This Meeting to the Trash",
                message: "It's still in your library. You can try moving its folder in Finder.",
            )
        }
    }

    func reveal(_ entry: MeetingEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.id])
    }

    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([library.root])
    }

    func openTrash() {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trash)
    }

    /// The meeting to select once this one is gone: the next one down, or else the one above.
    private func neighbor(of entry: MeetingEntry) -> URL? {
        let visible = sections.flatMap(\.entries)
        guard let index = visible.firstIndex(where: { $0.id == entry.id }) else {
            return nil
        }
        if index + 1 < visible.count {
            return visible[index + 1].id
        }
        return index > 0 ? visible[index - 1].id : nil
    }
}

// MARK: - Library location

extension LibraryStore {
    /// Before writing anything: is the library there? If not, asks what to do.
    func ensureLibraryIsAvailable() async -> Bool {
        prepare()
        guard let missingLocation else {
            return true
        }
        switch LibraryAlerts.askAboutMissingLibrary(at: missingLocation) {
        case .locate:
            await locateLibrary()
        case .useDefault:
            await useDefaultLocation()
        case .cancel:
            break
        }
        return self.missingLocation == nil
    }

    /// Asks where the library went, and uses that folder from now on.
    func locateLibrary() async {
        guard let folder = LibraryAlerts.chooseFolder(prompt: "Use This Folder", message: "Choose your Minutes folder.")
        else {
            return
        }
        do {
            try pointer.setRoot(folder)
        } catch {
            Self.logger.error("Saving the location failed: \(String(describing: error), privacy: .public)")
        }
        player.unload()
        selection = nil
        await refresh()
        TranscriptionCenter.shared.queue.resumeInterrupted(in: library)
    }

    func useDefaultLocation() async {
        do {
            try pointer.clear()
        } catch {
            Self.logger.error("Clearing the location failed: \(String(describing: error), privacy: .public)")
        }
        player.unload()
        selection = nil
        await refresh()
        TranscriptionCenter.shared.queue.resumeInterrupted(in: library)
    }

    /// Moves the whole library into a folder the user chooses.
    func moveLibrary() async {
        guard RecordingController.shared.phase == .idle, !TranscriptionCenter.shared.isBusy else {
            RecordingAlerts.show(
                title: "Minutes Is Busy",
                message: "Wait for recording, transcribing and downloads to finish, then move your library.",
            )
            return
        }
        guard let parent = LibraryAlerts.chooseFolder(
            prompt: "Move Here",
            message: "Your Minutes folder will move into the folder you choose.",
        ) else {
            return
        }
        isMovingLibrary = true
        player.unload()
        let selectionName = selection?.lastPathComponent
        let root = library.root
        let pointer = pointer
        let outcome = await Task.detached {
            Result {
                try LibraryMover.move(from: root, toParent: parent) { try pointer.setRoot($0) }
            }
        }.value
        isMovingLibrary = false

        switch outcome {
        case let .success(result):
            let reselect = selectionName.map {
                MinutesLibrary(root: result.newRoot).meetingsFolder.appendingPathComponent($0, isDirectory: true)
            }
            await refresh(selecting: reselect)
            if !result.removedOldFolder {
                RecordingAlerts.show(
                    title: "Your Library Moved",
                    message: "Minutes couldn't move the old folder to the Trash, so you can remove it yourself: "
                        + root.path,
                )
            }
        case let .failure(error):
            Self.logger.error("Moving the library failed: \(String(describing: error), privacy: .public)")
            RecordingAlerts.show(
                title: "Minutes Couldn't Move Your Library",
                message: LibraryAlerts.message(for: error),
            )
            await refresh()
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case allMeetings
    case chat

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .allMeetings: "All Meetings"
        case .chat: "Chat"
        }
    }

    var systemImage: String {
        switch self {
        case .allMeetings: "waveform"
        case .chat: "bubble.left.and.bubble.right"
        }
    }
}
