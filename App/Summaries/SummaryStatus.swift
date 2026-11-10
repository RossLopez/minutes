// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
import MinutesStorage

/// Where a meeting's summary stands.
enum SummaryStatus: Equatable {
    case writing(Summarizer.Stage?, text: String)
    /// In line. `held` when it's waiting for a recording or a transcript to finish.
    case waiting(held: Bool)
    case stopped
    case failed(String)
    case needsModel
    /// Nothing yet, and nothing under way.
    case notStarted
    /// The transcript isn't ready, so there's nothing to summarize.
    case noTranscript
    case complete
    case newerVersion
}

extension SummaryStatus {
    /// Being written or in line, so it can't be started again.
    var isUnderWay: Bool {
        switch self {
        case .writing, .waiting: true
        default: false
        }
    }
}

extension SummaryCenter {
    func status(for entry: MeetingEntry) -> SummaryStatus {
        if let activity = queue.activity, activity.folder == entry.id {
            return .writing(activity.stage, text: activity.text)
        }
        if queue.isWaiting(entry.id) {
            return .waiting(held: queue.isPaused)
        }
        guard let metadata = entry.metadata, !metadata.isNewerThanThisApp else {
            return .newerVersion
        }
        guard metadata.processing?.status == .complete else {
            return metadata.summary?.status == .complete ? .complete : .noTranscript
        }
        guard let summary = metadata.summary else {
            return hasModel ? .notStarted : .needsModel
        }
        switch summary.status {
        // Marked as queued but not in the queue, as in a folder copied in Finder mid-job.
        case .queued, .stopped: return .stopped
        case .failed: return .failed(summary.failure ?? "Minutes couldn't write this summary.")
        case .waitingForModel: return hasModel ? .stopped : .needsModel
        case .complete: return .complete
        }
    }

    /// For the meeting's row in the list, while there's something to say.
    func badge(for entry: MeetingEntry) -> String? {
        switch status(for: entry) {
        case .writing: "Summarizing…"
        case .waiting: "Waiting to summarize"
        case .failed: "Summary failed"
        case .stopped, .needsModel, .notStarted, .noTranscript, .complete, .newerVersion: nil
        }
    }

    /// Writes a summary, or a new one with `template`.
    func summarize(_ entry: MeetingEntry, template: String? = nil) {
        queue.enqueue(entry.id, template: template)
    }

    static func describe(_ stage: Summarizer.Stage?) -> String {
        switch stage {
        case nil: "Loading the model…"
        case let .readingPart(part, total): "Reading part \(part) of \(total)…"
        case .combiningNotes: "Combining notes…"
        case .writing: "Writing the summary…"
        }
    }
}
