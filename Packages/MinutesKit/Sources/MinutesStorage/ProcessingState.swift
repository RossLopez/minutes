// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A piece of work done after a recording stops. Later milestones add more.
public enum ProcessingStep: String, Codable, CaseIterable, Sendable {
    case cleanMic
    case transcribeMic
    case transcribeSystem
    /// Tells the other voices apart. Skipped, leaving them as Others, when the model isn't installed.
    case diarizeSystem
    case merge
}

/// The `processing` block in `meeting.json`. Meetings from before Milestone 3 don't have one.
public struct ProcessingState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Waiting or under way. Found like this at launch, it means the app quit or crashed, so it resumes.
        case queued
        /// The user cancelled. It stays that way, across launches, until they resume.
        case stopped
        case failed
        /// The transcription model isn't on this Mac, and downloading it is the user's call.
        case waitingForModel
        case complete
    }

    public var status: Status
    public var completedSteps: [ProcessingStep]
    /// The engine this run uses, so a resumed run doesn't mix engines between tracks.
    public var engine: String?
    /// Written for the user. Holds no transcript or note content.
    public var failure: String?

    public init(
        status: Status = .queued,
        completedSteps: [ProcessingStep] = [],
        engine: String? = nil,
        failure: String? = nil,
    ) {
        self.status = status
        self.completedSteps = completedSteps
        self.engine = engine
        self.failure = failure
    }
}
