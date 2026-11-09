// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesFluidAudio
import MinutesTranscription
import SwiftUI

struct TranscriptionSettingsTab: View {
    private let center = TranscriptionCenter.shared

    private var engineChoice: Binding<String> {
        Binding(get: { center.preferredEngineID }, set: { center.setPreferredEngine($0) })
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: engineChoice) {
                    Text("Apple Speech").tag(AppleSpeechEngine.engineID)
                    Text("Parakeet")
                        .tag(ParakeetEngine.engineID)
                        .disabled(center.modelStatuses[ParakeetEngine.engineID] != .installed)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("transcriptionEngine")
                ForEach(center.engines, id: \.id) { engine in
                    ModelRow(engine: engine)
                }
            } footer: {
                Text(
                    """
                    Both run only on this Mac. Parakeet got more specialist terms right in testing. \
                    It's downloaded from Hugging Face when you ask, and is made by NVIDIA under CC BY 4.0. \
                    A new engine applies to new transcripts, or use Transcribe Again on a meeting.
                    """,
                )
            }

            VocabularySection()

            SpeakerSettingsSection()
        }
        .formStyle(.grouped)
        .task {
            await center.refreshModelStatuses()
        }
    }
}

/// One engine's model: whether it's here, and getting or removing it.
private struct ModelRow: View {
    let engine: any TranscriptionEngine

    @State private var isConfirmingDelete = false

    private var center: TranscriptionCenter {
        .shared
    }

    private var downloadTitle: String {
        guard let size = engine.downloadSizeBytes else {
            return "Download"
        }
        return "Download (\(size.formatted(.byteCount(style: .file))))"
    }

    var body: some View {
        LabeledContent(engine.modelName) {
            if center.installingEngineID == engine.id {
                ProgressView(value: center.installProgress)
                    .frame(width: 120)
                    .accessibilityLabel("Downloading \(engine.modelName)")
                Button("Cancel") {
                    center.cancelInstall()
                }
            } else {
                switch center.modelStatuses[engine.id] {
                case .none:
                    ProgressView().controlSize(.small)
                case .installed:
                    installed
                case .notInstalled:
                    if center.installFailed {
                        Text("Download failed")
                            .foregroundStyle(.secondary)
                    }
                    Button(downloadTitle) {
                        center.installModel(for: engine.id)
                    }
                    .disabled(center.installingEngineID != nil)
                    .accessibilityIdentifier("downloadModel-\(engine.id)")
                case let .unavailable(reason):
                    Text(reason)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var installed: some View {
        Text("Ready")
            .foregroundStyle(.secondary)
        if engine.canRemoveModel {
            Button("Delete") {
                isConfirmingDelete = true
            }
            .disabled(center.queue.isBusy)
            .help(center.queue.isBusy ? "Available when transcribing finishes" : "")
            .confirmationDialog("Delete \(engine.modelName)?", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive) {
                    Task {
                        await center.removeModel(for: engine.id)
                    }
                }
            } message: {
                Text("Existing transcripts stay. You can download it again later.")
            }
        }
    }
}
