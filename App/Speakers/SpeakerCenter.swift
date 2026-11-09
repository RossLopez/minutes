// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesDiarization
import MinutesPipeline
import MinutesStorage
import Observation
import os

enum SpeakerPreferences {
    static let remembersVoicesKey = "speakers.remembersVoices"
    static let yourNameKey = "general.yourName"

    /// Off until the user turns it on, since voice profiles are biometric data about other people.
    static var remembersVoices: Bool {
        UserDefaults.standard.bool(forKey: remembersVoicesKey)
    }

    /// The name shown for Me. The Mac account's full name until the user changes it.
    static var yourName: String {
        UserDefaults.standard.string(forKey: yourNameKey) ?? NSFullUserName()
    }
}

/// Naming and fixing speakers, the diarizer's model, and saved voices.
@MainActor @Observable
final class SpeakerCenter {
    static let shared = SpeakerCenter()

    private nonisolated static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "speakers")

    private(set) var modelStatus: DiarizationModelStatus?
    private(set) var isInstalling = false
    private(set) var installProgress = 0.0
    private(set) var installFailed = false
    private(set) var profiles: [SpeakerProfile] = []
    /// Meetings with an edit under way, so their controls wait.
    private(set) var editingFolders: Set<URL> = []
    /// Goes up with every edit to a meeting's speakers, so its transcript reloads.
    private(set) var revisions: [URL: Int] = [:]
    /// Something an edit wants the user to know, like a voice that couldn't be remembered.
    var notice: String?

    var remembersVoices = SpeakerPreferences.remembersVoices {
        didSet {
            UserDefaults.standard.set(remembersVoices, forKey: SpeakerPreferences.remembersVoicesKey)
        }
    }

    @ObservationIgnored private var installTask: Task<Void, Never>?

    private init() {}

    var diarizer: any SpeakerDiarizer {
        TranscriptionCenter.shared.diarizer
    }

    private var naming: SpeakerNaming {
        SpeakerNaming(
            diarizer: { [diarizer] in diarizer },
            profiles: LibraryStore.shared.library.speakerProfiles,
            remembersVoices: { SpeakerPreferences.remembersVoices },
        )
    }

    // MARK: - Model and profiles

    func refresh() async {
        modelStatus = await diarizer.modelStatus()
        let store = LibraryStore.shared.library.speakerProfiles
        profiles = await Task.detached { store.profiles() }.value
    }

    /// Only ever called from a button the user pressed.
    func installModel() {
        guard !isInstalling else {
            return
        }
        isInstalling = true
        installProgress = 0
        installFailed = false
        let diarizer = diarizer
        installTask = Task {
            do {
                try await diarizer.installModel { fraction in
                    Task { @MainActor in
                        SpeakerCenter.shared.installProgress = fraction
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    Self.logger.error("Model download failed: \(String(describing: type(of: error)), privacy: .public)")
                    installFailed = true
                }
            }
            isInstalling = false
            installTask = nil
            await refresh()
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func removeModel() async {
        do {
            try await diarizer.removeModel()
        } catch {
            Self.logger.error("Removing a model failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        await refresh()
    }

    func deleteProfile(_ id: UUID) async {
        let store = LibraryStore.shared.library.speakerProfiles
        await run("Couldn't delete a voice") { try store.delete(id) }
        await refresh()
    }

    func deleteAllProfiles() async {
        let store = LibraryStore.shared.library.speakerProfiles
        await run("Couldn't delete voices") { try store.deleteAll() }
        await refresh()
    }

    // MARK: - Editing a meeting's speakers

    func canEdit(_ entry: MeetingEntry) -> Bool {
        TranscriptionCenter.shared.status(for: entry) == .idle && !editingFolders.contains(entry.id)
            && entry.canRename
    }

    /// Offered for meetings whose other voices are all still Others.
    func canIdentifySpeakers(in entry: MeetingEntry) -> Bool {
        modelStatus == .installed && TranscriptionCenter.shared.status(for: entry) == .idle
    }

    func identifySpeakers(in entry: MeetingEntry) {
        TranscriptionCenter.shared.queue.identifySpeakers(entry.id)
    }

    func name(_ speaker: String, in entry: MeetingEntry, to name: String?) async {
        let naming = naming
        let folder = entry.folder
        await edit(entry) {
            let outcome = try await Task.detached { try await naming.name(speaker, in: folder, to: name) }.value
            switch outcome {
            case .notEnoughSpeech:
                self.notice = "This speaker talks for less than \(Int(SpeakerNaming.minimumSpeech)) seconds, "
                    + "which is too little to remember their voice. The name is saved for this meeting."
            case .modelMissing:
                self.notice = "To remember voices, download the speaker model in Settings → Transcription. "
                    + "The name is saved for this meeting."
            case .named, .remembered:
                break
            }
        }
    }

    func merge(_ speaker: String, into target: String, in entry: MeetingEntry) async {
        let naming = naming
        let folder = entry.folder
        await edit(entry) {
            try await Task.detached { try await naming.merge(speaker, into: target, in: folder) }.value
        }
    }

    /// `nil` gives the line to someone new.
    func moveLine(at index: Int, to speaker: String?, in entry: MeetingEntry) async {
        let folder = entry.folder
        await edit(entry) {
            _ = try await Task.detached { try folder.moveLine(at: index, to: speaker) }.value
        }
    }

    func declineSuggestion(for speaker: String, in entry: MeetingEntry) async {
        let folder = entry.folder
        await edit(entry) {
            try await Task.detached { try folder.declineSuggestion(for: speaker) }.value
        }
    }

    /// Accepting puts the name on and, with memory on, adds this meeting's voice to that profile.
    func acceptSuggestion(for speaker: String, in entry: MeetingEntry) async {
        guard let suggestion = entry.metadata?.speakers?[speaker]?.suggestion else {
            return
        }
        await name(speaker, in: entry, to: suggestion.name)
    }

    private func edit(_ entry: MeetingEntry, _ body: () async throws -> Void) async {
        editingFolders.insert(entry.id)
        defer {
            editingFolders.remove(entry.id)
            revisions[entry.id, default: 0] += 1
        }
        do {
            try await body()
        } catch {
            Self.logger.error("Speaker edit failed: \(String(describing: type(of: error)), privacy: .public)")
            notice = Self.describe(error)
        }
        await LibraryStore.shared.refresh()
        await refresh()
    }

    private func run(_ what: String, _ body: @escaping @Sendable () throws -> Void) async {
        do {
            try await Task.detached { try body() }.value
        } catch {
            Self.logger.error("\(what, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
            notice = "\(what). Check that the Speakers folder can be changed."
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case MeetingFolder.SpeakerEditError.meetingBusy:
            "This meeting is being transcribed. Try again when it's done."
        case MeetingFolder.FolderError.newerFileFormat:
            "This meeting was saved by a newer version of Minutes."
        default:
            "Minutes couldn't change this meeting's speakers."
        }
    }
}
