// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesDiarization
import MinutesStorage
import MinutesTranscription

// MARK: - Telling speakers apart

extension MeetingPipeline {
    /// Sets a finished meeting up to run only diarization and merging again, with the words it
    /// already has. Both tracks' words come back out of `transcript.json`.
    public static func prepareToIdentifySpeakers(_ folder: MeetingFolder) throws {
        let transcript = try folder.loadTranscript()
        guard !transcript.isNewerThanThisApp else {
            throw MeetingFolder.FolderError.newerFileFormat
        }
        func words(where isMine: Bool) -> [TranscriptWord] {
            transcript.segments
                .filter { ($0.speaker == Transcript.Speaker.me) == isMine }
                .flatMap(\.words)
                .sorted { $0.start < $1.start }
        }
        let manager = FileManager.default
        try? manager.removeItem(at: folder.processingFolder)
        try manager.createDirectory(at: folder.processingFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(words(where: true)).write(to: wordsFile(.transcribeMic, in: folder), options: .atomic)
        try JSONEncoder().encode(words(where: false))
            .write(to: wordsFile(.transcribeSystem, in: folder), options: .atomic)
        try folder.updateMetadata { metadata in
            metadata.processing = ProcessingState(
                completedSteps: [.cleanMic, .transcribeMic, .transcribeSystem],
                engine: transcript.engine,
            )
        }
    }

    /// Never fails the meeting: if the diarizer can't run, the other voices stay as Others.
    func performDiarization(_ context: StepContext) async throws {
        let manager = FileManager.default
        let folder = context.folder
        var record = DiarizationRecord(diarization: nil)
        if let diarizer = diarizer(),
           manager.fileExists(atPath: folder.systemAudio.path),
           try !Self.loadWords(.transcribeSystem, in: folder).isEmpty,
           await diarizer.modelStatus() == .installed
        {
            let work = folder.processingFolder.appendingPathComponent("work-diarizeSystem", isDirectory: true)
            try? manager.removeItem(at: work)
            try manager.createDirectory(at: work, withIntermediateDirectories: true)
            do {
                let diarization = try await diarizer.diarize(
                    audio: folder.systemAudio,
                    workFolder: work,
                    progress: context.progress,
                )
                try Task.checkCancellation()
                record.diarization = diarization
                Self.logger.info("Diarization found \(diarization.speakers.count, privacy: .public) speakers")
            } catch {
                if error is CancellationError || Task.isCancelled || context.location.folder != folder {
                    throw error
                }
                Self.logger.error("Diarization failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        let data = try JSONEncoder().encode(record)
        try context.location.access { current in
            try data.write(to: Self.wordsFile(.diarizeSystem, in: current), options: .atomic)
            try? manager.removeItem(at: current.processingFolder.appendingPathComponent("work-diarizeSystem"))
        }
    }

    /// Works out the transcript and names, keeps them in `.processing/merge.json`, then writes
    /// them out. A crash between writing `transcript.json` and `meeting.json` just writes them again.
    func performMerge(location: MeetingLocation, engine: any TranscriptionEngine) throws {
        try location.access { folder in
            let pending = folder.processingFolder.appendingPathComponent("merge.json")
            let merged: MergeResult
            if let data = try? Data(contentsOf: pending),
               let saved = try? JSONDecoder().decode(MergeResult.self, from: data)
            {
                merged = saved
            } else {
                merged = try merge(in: folder, engine: engine)
                try JSONEncoder().encode(merged).write(to: pending, options: .atomic)
            }
            let metadata = try folder.updateSpeakers { $0 = merged.speakers }
            try folder.save(merged.transcript, for: metadata)
        }
    }

    private func merge(in folder: MeetingFolder, engine: any TranscriptionEngine) throws -> MergeResult {
        let replacer = VocabularyReplacer(entries: vocabulary())
        let mine = try replacer.apply(to: Self.loadWords(.transcribeMic, in: folder))
        let theirs = try replacer.apply(to: Self.loadWords(.transcribeSystem, in: folder))
        let diarization = (try? Data(contentsOf: Self.wordsFile(.diarizeSystem, in: folder)))
            .flatMap { try? JSONDecoder().decode(DiarizationRecord.self, from: $0) }?
            .diarization

        var systemSegments = TranscriptAssembler.segments(from: theirs, speaker: Transcript.Speaker.others)
        var voices: [String: [Float]] = [:]
        if let diarization, !diarization.turns.isEmpty {
            let attribution = SpeakerAttribution.attribute(theirs, to: diarization)
            systemSegments = TranscriptAssembler.segments(from: theirs, speakers: attribution.speakers)
            for (engineID, speaker) in attribution.ids {
                voices[speaker] = diarization.embeddings[engineID]
            }
        }
        let transcript = Transcript(
            engine: engine.id,
            model: engine.modelName,
            segments: TranscriptAssembler.merge(
                TranscriptAssembler.segments(from: mine, speaker: Transcript.Speaker.me),
                systemSegments,
            ),
        )
        return MergeResult(transcript: transcript, speakers: names(for: transcript, voices: voices, in: folder))
    }

    /// Names kept from the transcript being replaced, your name for Me, then saved voices for
    /// anyone still unnamed.
    private func names(
        for transcript: Transcript,
        voices: [String: [Float]],
        in folder: MeetingFolder,
    ) -> [String: MeetingMetadata.Speaker] {
        var speakers: [String: MeetingMetadata.Speaker] = [:]
        if let old = try? folder.loadTranscript(), let metadata = try? folder.loadMetadata() {
            speakers = NameCarryOver.carry(from: old.segments, names: metadata.speakers ?? [:], to: transcript.segments)
        }
        if speakers[Transcript.Speaker.me]?.name == nil,
           let name = yourName()?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        {
            speakers[Transcript.Speaker.me, default: MeetingMetadata.Speaker()].name = name
        }

        guard let store = speakerMemory(), !voices.isEmpty else {
            return speakers
        }
        let takenNames = Set(speakers.values.compactMap { $0.name?.lowercased() })
        let takenProfiles = Set(speakers.values.compactMap(\.profile))
        let profiles = store.profiles().filter {
            !takenProfiles.contains($0.id) && !takenNames.contains($0.name.lowercased())
        }
        let unnamed = voices.filter { speakers[$0.key]?.name == nil }
        let declined = unnamed.keys.reduce(into: [String: Set<UUID>]()) { result, speaker in
            result[speaker] = Set(speakers[speaker]?.declinedProfiles ?? [])
        }
        for (speaker, match) in VoiceMatcher.match(unnamed, against: profiles, declined: declined) {
            var entry = speakers[speaker] ?? MeetingMetadata.Speaker()
            switch match {
            case let .applied(profile, name):
                entry.name = name
                entry.profile = profile
                entry.suggestion = nil
            case let .suggested(profile, name):
                entry.suggestion = MeetingMetadata.Suggestion(name: name, profile: profile)
            }
            speakers[speaker] = entry
        }
        let matched = speakers.values.count { $0.profile != nil || $0.suggestion != nil }
        Self.logger.info("Matched \(matched, privacy: .public) voices")
        return speakers
    }
}

/// What the diarization step found. `nil` when it was skipped.
struct DiarizationRecord: Codable {
    var diarization: Diarization?
}

struct MergeResult: Codable {
    var transcript: Transcript
    var speakers: [String: MeetingMetadata.Speaker]
}
