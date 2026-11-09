// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesStorage
import SwiftUI

/// Settings → Transcription → Speakers: the diarizer's model, speaker memory and saved voices.
struct SpeakerSettingsSection: View {
    @State private var isConfirmingModelDelete = false
    @State private var isExplainingMemory = false
    @State private var isConfirmingDeleteAll = false

    private var center: SpeakerCenter {
        .shared
    }

    private var remembersVoices: Binding<Bool> {
        Binding(
            get: { center.remembersVoices },
            set: { isOn in
                if isOn {
                    isExplainingMemory = true
                } else {
                    center.remembersVoices = false
                }
            },
        )
    }

    var body: some View {
        Section {
            LabeledContent(center.diarizer.modelName) {
                model
            }
            Toggle("Remember voices", isOn: remembersVoices)
                .accessibilityIdentifier("rememberVoices")
                .alert("Remember Voices?", isPresented: $isExplainingMemory) {
                    Button("Remember Voices") {
                        center.remembersVoices = true
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(Self.memoryExplanation)
                }
            if !center.profiles.isEmpty {
                profiles
            }
        } header: {
            Text("Speakers")
        } footer: {
            Text(
                """
                The speaker model tells the other voices in a meeting apart, on this Mac. It's downloaded from \
                Hugging Face when you ask, and is based on pyannote's Community-1 under CC BY 4.0. \
                With Remember voices on, naming someone saves their voice in the Speakers folder so later \
                meetings can name them too.
                """,
            )
        }
        .task {
            await center.refresh()
        }
    }

    static let memoryExplanation = """
    A voice profile is biometric data about another person. Minutes keeps profiles only on this Mac, \
    in the Speakers folder, and you can delete them at any time. Getting people's consent is up to you.
    """

    @ViewBuilder
    private var model: some View {
        if center.isInstalling {
            ProgressView(value: center.installProgress)
                .frame(width: 120)
                .accessibilityLabel("Downloading \(center.diarizer.modelName)")
            Button("Cancel") {
                center.cancelInstall()
            }
        } else {
            switch center.modelStatus {
            case .none:
                ProgressView().controlSize(.small)
            case .installed:
                Text("Ready")
                    .foregroundStyle(.secondary)
                Button("Delete") {
                    isConfirmingModelDelete = true
                }
                .disabled(TranscriptionCenter.shared.queue.isBusy)
                .help(TranscriptionCenter.shared.queue.isBusy ? "Available when transcribing finishes" : "")
                .confirmationDialog("Delete \(center.diarizer.modelName)?", isPresented: $isConfirmingModelDelete) {
                    Button("Delete", role: .destructive) {
                        Task {
                            await center.removeModel()
                        }
                    }
                } message: {
                    Text("Names already given stay. New meetings will show other voices as Others.")
                }
            case .notInstalled:
                if center.installFailed {
                    Text("Download failed")
                        .foregroundStyle(.secondary)
                }
                Button("Download (\(center.diarizer.downloadSizeBytes.formatted(.byteCount(style: .file))))") {
                    center.installModel()
                }
                .accessibilityIdentifier("downloadSpeakerModel")
            case let .unavailable(reason):
                Text(reason)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profiles: some View {
        ForEach(center.profiles) { profile in
            SpeakerProfileRow(profile: profile)
        }
        Button("Delete All Voices…", role: .destructive) {
            isConfirmingDeleteAll = true
        }
        .confirmationDialog("Delete all saved voices?", isPresented: $isConfirmingDeleteAll) {
            Button("Delete All", role: .destructive) {
                Task {
                    await center.deleteAllProfiles()
                }
            }
        } message: {
            Text("Names in past meetings stay. Minutes stops recognizing these voices.")
        }
    }
}

private struct SpeakerProfileRow: View {
    let profile: SpeakerProfile

    private var detail: String {
        let meetings = profile.samples.count == 1 ? "1 meeting" : "\(profile.samples.count) meetings"
        guard let lastHeard = profile.lastHeard else {
            return meetings
        }
        return "\(meetings), last heard \(lastHeard.formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        LabeledContent {
            Button("Delete") {
                Task {
                    await SpeakerCenter.shared.deleteProfile(profile.id)
                }
            }
            .accessibilityLabel("Delete \(profile.name)'s voice")
        } label: {
            Text(profile.name)
            Text(detail)
        }
    }
}
