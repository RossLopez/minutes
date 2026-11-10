// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import MinutesStorage

/// One summary, off the main actor: reads the meeting, has the model write, and saves the result.
enum SummaryRun {
    static func summarize(
        at location: MeetingLocation,
        provider: any LLMProvider,
        templates: SummaryTemplateStore,
        stage: @escaping @Sendable (Summarizer.Stage) -> Void,
        emit: @escaping @Sendable (String) -> Void,
    ) async throws {
        let (metadata, transcript) = try location.access { folder in
            try (folder.loadMetadata(), folder.loadTranscript())
        }
        let template = templates.template(named: metadata.summary?.nextTemplate ?? SummaryTemplateStore.defaultName)
        var names: [String: String] = [:]
        let lines = transcript.segments.map { segment in
            let name = metadata.displayName(forSpeaker: segment.speaker)
            names[segment.speaker] = name
            return SummaryLine(start: segment.start, speaker: name, text: segment.text)
        }
        let text = try await Summarizer(provider: provider).summarize(
            lines,
            about: metadata.title,
            instructions: template.prompt,
            stage: stage,
            emit: emit,
        )
        try Task.checkCancellation()
        _ = try location.access { folder in
            try folder.saveSummary(text, template: template.name, model: provider.id, names: names)
        }
    }

    /// For the Summary tab. Never includes meeting text.
    static func describe(_ error: any Error) -> String {
        switch error {
        case LLMError.modelUnavailable:
            SummaryQueue.modelNotInstalled
        case let LLMError.loadFailed(reason), let LLMError.generationFailed(reason):
            reason
        case LLMError.promptTooLong:
            "Part of the transcript is too long for the model to read."
        case MeetingFolder.FolderError.newerFileFormat:
            "This meeting was saved by a newer version of Minutes."
        default:
            "The summary couldn't be written."
        }
    }
}
