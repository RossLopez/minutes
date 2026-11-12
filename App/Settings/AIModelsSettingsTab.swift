// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import SwiftUI

struct AIModelsSettingsTab: View {
    @Bindable private var center = SummaryCenter.shared

    private var models: AIModelCenter {
        .shared
    }

    /// Where summaries are written, said plainly.
    private var summaryFooter: String {
        var place: String?
        if case let .endpoint(id, _)? = center.summaryChoice, let endpoint = models.endpoint(id) {
            place = "Transcripts are sent to \(endpoint.name) at \(endpoint.baseURL.host() ?? "its address")."
        }
        return (place ?? "Summaries are written on this Mac. Nothing is sent anywhere.")
            + " Turn off automatic summaries to summarize from a meeting's Summary tab instead."
    }

    var body: some View {
        Form {
            Section {
                ModelChoicePicker(title: "Default model", feature: nil)
                ForEach(AIFeature.allCases) { feature in
                    ModelChoicePicker(title: feature.title, feature: feature)
                }
            } footer: {
                Text("""
                Notes cleanup and Chat arrive in a later version of Minutes. What you choose for them now \
                is kept.
                """)
            }

            Section {
                Toggle("Summarize meetings automatically", isOn: $center.summarizesAutomatically)
                    .accessibilityIdentifier("summarizeAutomatically")
            } footer: {
                Text(summaryFooter)
            }

            EndpointsSection()

            Section {
                ForEach(ModelCatalog.all.filter { !$0.isAdvanced }) { model in
                    CatalogModelRow(model: model)
                }
            } header: {
                Text("Built-in models")
            } footer: {
                Text("""
                Gemma 4 by Google, under the Apache License 2.0. Downloaded from Hugging Face only when you \
                click Download, and checked before use. 12B writes the best summaries. E4B and E2B are \
                faster and need less memory.
                """)
            }

            Section("Advanced: for Macs with 32 GB of memory or more") {
                ForEach(ModelCatalog.all.filter(\.isAdvanced)) { model in
                    CatalogModelRow(model: model)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            center.refreshModels()
        }
    }
}

/// One catalog model: its size and memory, and getting, pausing or deleting it.
private struct CatalogModelRow: View {
    let model: CatalogModel

    @State private var isConfirmingDelete = false

    private var center: SummaryCenter {
        .shared
    }

    private var details: String {
        var text = "About \(SummaryCenter.bytes(model.approximateBytes)) · \(model.recommendedMemoryGB) GB of memory"
        if !model.fitsMemory() {
            text += " · more than this Mac has"
        }
        return text
    }

    var body: some View {
        LabeledContent {
            HStack {
                controls
            }
        } label: {
            Text(model.name)
            Text(details)
            if let failure = center.downloadFailures[model.id] {
                Text(failure)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityIdentifier("model-\(model.id)")
    }

    @ViewBuilder
    private var controls: some View {
        switch center.states[model.id] ?? .notInstalled {
        case .notInstalled:
            ModelDownloadButton(model: model)
        case let .downloading(progress):
            Text(progressText(progress))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
                .accessibilityHidden(true)
            ProgressView(value: progress?.fraction ?? 0)
                .frame(width: 90)
                .accessibilityLabel("Downloading \(model.name)")
                .accessibilityValue(progressText(progress))
            Button("Pause") {
                center.pauseDownload(of: model)
            }
            Button("Cancel") {
                center.cancelDownload(of: model)
            }
        case let .paused(progress):
            Text(progressText(progress))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Button("Resume") {
                center.download(model)
            }
            Button("Cancel") {
                center.cancelDownload(of: model)
            }
        case .installed:
            Text("Ready")
                .foregroundStyle(.secondary)
            Button("Delete") {
                isConfirmingDelete = true
            }
            .disabled(center.isInUse(model))
            .help(center.isInUse(model) ? "Available when the summary under way finishes" : "")
            .confirmationDialog("Delete \(model.name)?", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive) {
                    Task {
                        await center.delete(model)
                    }
                }
            } message: {
                Text("Existing summaries stay. You can download it again later.")
            }
        }
    }

    private func progressText(_ progress: DownloadProgress?) -> String {
        guard let progress else {
            return "Starting…"
        }
        return "\(SummaryCenter.bytes(progress.received)) of \(SummaryCenter.bytes(progress.total))"
    }
}
