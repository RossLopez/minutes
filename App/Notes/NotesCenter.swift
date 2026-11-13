// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage
import Observation
import os

/// One meeting's notes while the app has them open.
@MainActor @Observable
final class NotesDocument {
    let meetingID: UUID
    /// Follows the meeting when it's renamed.
    fileprivate(set) var folder: URL
    fileprivate(set) var text: String
    fileprivate(set) var times: [Double?]
    fileprivate(set) var cleaned: NoteTimes.Cleaned?
    fileprivate(set) var cleanedText: String?
    /// Said for the user when the last save failed.
    fileprivate(set) var saveFailure: String?

    @ObservationIgnored fileprivate var saveTask: Task<Void, Never>?
    /// When `notes.md` last changed as far as this document knows, to notice edits elsewhere.
    @ObservationIgnored fileprivate var diskDate: Date?

    fileprivate init(meetingID: UUID, folder: URL) {
        self.meetingID = meetingID
        self.folder = folder
        text = ""
        times = [nil]
    }

    var lines: [String] {
        NoteTimeline.lines(of: text)
    }

    var hasText: Bool {
        !text.allSatisfy(\.isWhitespace)
    }

    var hasUnsavedChanges: Bool {
        saveTask != nil
    }

    fileprivate func load() {
        let meeting = MeetingFolder(url: folder)
        let notes = meeting.loadNotes()
        text = notes.text
        times = notes.times
        cleaned = notes.cleaned
        cleanedText = meeting.loadCleanedNotes()
        diskDate = Self.modificationDate(of: meeting.notesFile)
    }

    static func modificationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Meeting notes for the whole app: typing and autosave, line times while recording, and
/// cleanups. Documents are kept by meeting ID, so a rename doesn't lose what's waiting to save.
@MainActor @Observable
final class NotesCenter {
    static let shared = NotesCenter()

    nonisolated static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "notes")
    static let saveDelay = Duration.seconds(1)

    @ObservationIgnored private var documents: [UUID: NotesDocument] = [:]
    /// Cleanups by meeting ID: under way, or waiting to be accepted or discarded.
    var cleanups: [UUID: NotesCleanupRun] = [:]

    private init() {}

    /// The meeting's notes, read from disk the first time.
    func document(for entry: MeetingEntry) -> NotesDocument? {
        guard let id = entry.metadata?.id else {
            return nil
        }
        if let document = documents[id] {
            if document.folder != entry.id, !document.hasUnsavedChanges {
                document.folder = entry.id
            }
            return document
        }
        let document = NotesDocument(meetingID: id, folder: entry.id)
        document.load()
        documents[id] = document
        return document
    }

    // MARK: - Typing

    /// Takes the editor's new text, times its lines, and saves soon.
    func edit(_ document: NotesDocument, text: String) {
        guard text != document.text else {
            return
        }
        document.times = NoteTimeline.update(
            old: document.lines,
            new: NoteTimeline.lines(of: text),
            times: document.times,
            now: recordingSeconds(for: document),
        )
        document.text = text
        document.saveTask?.cancel()
        document.saveTask = Task { [weak self, weak document] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let document else {
                return
            }
            self?.save(document)
        }
    }

    /// Seconds into the recording, while this meeting is being recorded.
    private func recordingSeconds(for document: NotesDocument) -> Double? {
        let recorder = RecordingController.shared
        guard recorder.isRecording, recorder.activeFolder == document.folder else {
            return nil
        }
        return Double(recorder.startedAt.duration(to: .now) / .milliseconds(1)) / 1000
    }

    /// Recording takes the Mac's attention, so cleanups stop as it starts. When it stops, the
    /// notes are saved before the meeting is.
    func recordingPhaseChanged(from old: RecordingController.Phase, to new: RecordingController.Phase,
                               folder: URL?)
    {
        if old == .idle, new == .starting {
            stopCleanupsForRecording()
        }
        if old == .recording, let folder {
            flush(folder)
        }
    }

    /// Whether this meeting is being recorded, so its notes are being timed.
    func isRecording(_ document: NotesDocument) -> Bool {
        RecordingController.shared.activeFolder == document.folder
    }

    private func save(_ document: NotesDocument) {
        document.saveTask?.cancel()
        document.saveTask = nil
        let folder = MeetingFolder(url: document.folder)
        do {
            try folder.saveNotes(MeetingNotes(text: document.text, times: document.times, cleaned: document.cleaned))
            document.diskDate = NotesDocument.modificationDate(of: folder.notesFile)
            document.saveFailure = nil
        } catch {
            Self.logger.error("Saving notes failed: \(String(describing: type(of: error)), privacy: .public)")
            document.saveFailure = "Minutes couldn't save your notes. They're kept here and saved again as you type."
        }
    }

    // MARK: - Saving now

    /// Saves anything waiting for this meeting folder.
    func flush(_ folder: URL) {
        for document in documents.values where document.folder == folder && document.hasUnsavedChanges {
            save(document)
        }
    }

    func flushAll() {
        for document in documents.values where document.hasUnsavedChanges {
            save(document)
        }
    }

    /// Reads notes again if they changed on disk and nothing here is waiting to save.
    func reloadIfChanged(_ document: NotesDocument) {
        guard !document.hasUnsavedChanges else {
            return
        }
        let folder = MeetingFolder(url: document.folder)
        let date = NotesDocument.modificationDate(of: folder.notesFile)
        let cleanedChanged = folder.loadCleanedNotes() != document.cleanedText
        if date != document.diskDate || cleanedChanged {
            document.load()
        }
    }

    // MARK: - Library changes

    func folderMoved(from old: URL, to new: URL) {
        for document in documents.values where document.folder == old {
            document.folder = new
        }
    }

    /// The meeting went to the Trash. Its notes were saved first.
    func forget(_ folder: URL) {
        for (id, document) in documents where document.folder == folder {
            cleanups[id]?.cancel()
            cleanups[id] = nil
            documents[id] = nil
        }
    }

    /// Another library: every meeting is somewhere else, or gone. Save first if they can be.
    func libraryChanged() {
        for run in cleanups.values {
            run.cancel()
        }
        cleanups.removeAll()
        documents.removeAll()
    }

    /// The app is quitting. Unsaved notes are written, and cleanups stop without writing.
    func prepareForExit() {
        flushAll()
        for run in cleanups.values {
            run.cancel()
        }
    }

    private func reload(_ document: NotesDocument) {
        document.load()
    }
}

extension NotesCenter {
    /// After a cleanup is accepted, so the document shows it.
    func cleanedNotesSaved(for document: NotesDocument) {
        reload(document)
    }
}
