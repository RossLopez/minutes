// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesPipeline
import MinutesStorage
import SwiftUI

/// A meeting's transcript work: how far along it is, or what it needs from the user.
struct TranscriptStatusView: View {
    let entry: MeetingEntry
    let status: TranscriptStatus

    private var center: TranscriptionCenter {
        .shared
    }

    var body: some View {
        switch status {
        case let .working(progress):
            working(progress)
        case .waiting:
            message(
                center.queue.isPaused
                    ? "Transcribing starts after this recording."
                    : "Waiting for another meeting to finish transcribing.",
                systemImage: "clock",
            ) {
                Button("Cancel") {
                    center.queue.stop(entry.id)
                }
                .accessibilityIdentifier("transcriptCancel")
            }
        case .stopped:
            message("Transcribing stopped.", systemImage: "pause.circle") {
                Button("Resume") {
                    center.queue.enqueue(entry.id)
                }
                .accessibilityIdentifier("transcriptResume")
            }
        case let .failed(reason):
            message(reason, systemImage: "exclamationmark.triangle") {
                Button("Retry") {
                    center.queue.enqueue(entry.id)
                }
                .accessibilityIdentifier("transcriptRetry")
            }
        case let .needsModel(engineID):
            ModelNeededView(engineID: engineID)
        case .notStarted, .idle:
            message("This meeting doesn't have a transcript yet.", systemImage: "text.quote") {
                Button("Transcribe") {
                    center.transcribe(entry)
                }
                .disabled(center.transcribeTitle(for: entry) == nil)
                .accessibilityIdentifier("transcriptTranscribe")
            }
        case .newerVersion:
            EmptyView()
        }
    }

    private func working(_ progress: PipelineProgress?) -> some View {
        let description = Self.describe(progress)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(description)
                    .font(.callout)
                Spacer()
                Button("Cancel") {
                    center.queue.stop(entry.id)
                }
                .accessibilityIdentifier("transcriptCancel")
            }
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(description)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(description)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcriptProgress")
    }

    private static func describe(_ progress: PipelineProgress?) -> String {
        guard let progress else {
            return "Getting ready…"
        }
        let steps = ProcessingStep.allCases
        let number = (steps.firstIndex(of: progress.step) ?? 0) + 1
        let name = switch progress.step {
        case .cleanMic: "Removing speaker echo from your microphone"
        case .transcribeMic: "Transcribing your microphone"
        case .transcribeSystem: "Transcribing system audio"
        case .diarizeSystem: "Telling speakers apart"
        case .merge: "Putting the transcript together"
        }
        return "Step \(number) of \(steps.count): \(name)"
    }

    private func message(
        _ text: String,
        systemImage: String,
        @ViewBuilder action: () -> some View,
    ) -> some View {
        HStack {
            Label(text, systemImage: systemImage)
                .font(.callout)
            Spacer()
            action()
        }
    }
}

/// The engine's model isn't here. Nothing downloads until the user says so.
private struct ModelNeededView: View {
    let engineID: String

    private var center: TranscriptionCenter {
        .shared
    }

    private var explanation: String {
        guard let engine = center.engine(withID: engineID) else {
            return "This meeting's transcription engine isn't available. Choose another in Settings."
        }
        guard let size = engine.downloadSizeBytes else {
            return "To transcribe, macOS needs to download Apple's speech model. "
                + "It doesn't say how big that is until it starts."
        }
        return "To transcribe with \(engine.modelName), Minutes needs to download "
            + "\(size.formatted(.byteCount(style: .file))). The meeting will wait until you do."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(explanation, systemImage: "arrow.down.circle")
                .font(.callout)
            if center.installingEngineID == engineID {
                HStack {
                    ProgressView(value: center.installProgress)
                        .accessibilityLabel("Downloading")
                    Button("Cancel") {
                        center.cancelInstall()
                    }
                }
            } else {
                HStack {
                    Button("Download") {
                        center.installModel(for: engineID)
                    }
                    .disabled(center.installingEngineID != nil || center.engine(withID: engineID) == nil)
                    .accessibilityIdentifier("transcriptDownload")
                    Button("Transcription Settings…") {
                        RecordingController.shared.openSettings(.transcription)
                    }
                }
                if center.installFailed {
                    Text("The download didn't finish. Check your connection and try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
