// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesLLM
import MinutesStorage
import SwiftUI

/// The Summary tab: the summary as it's written, then the summary with its versions and template.
struct SummaryTab: View {
    let entry: MeetingEntry

    @State private var text: String?
    /// Which summary `text` was read for, so a missing file isn't mistaken for one still loading.
    @State private var loadedKey: LoadKey?
    @State private var templates: [SummaryTemplate] = []
    @State private var confirmTemplate: String?
    @State private var previous: PreviousSummary?

    private var center: SummaryCenter {
        .shared
    }

    private var summary: MeetingMetadata.Summary? {
        entry.metadata?.summary
    }

    private struct LoadKey: Equatable {
        let folder: URL
        let summary: MeetingMetadata.Summary?
    }

    private var key: LoadKey {
        LoadKey(folder: entry.id, summary: summary)
    }

    var body: some View {
        let status = center.status(for: entry)
        // Color.clear is always there, so the tasks below run even while the switch has nothing
        // to show, as for a finished summary whose text hasn't been read yet.
        ZStack(alignment: .top) {
            Color.clear
            switch status {
            case let .writing(stage, written):
                content(written, status: status, stage: stage)
            case .complete:
                if let text {
                    content(text, status: status, stage: nil)
                } else if loadedKey == key {
                    ContentUnavailableView(
                        "Minutes Can't Read This Summary",
                        systemImage: "exclamationmark.triangle",
                        description: Text("summary.md is missing or isn't plain text."),
                    )
                }
            case .waiting, .stopped, .failed:
                if let text {
                    content(text, status: status, stage: nil)
                } else {
                    centered { SummaryStatusView(entry: entry, status: status) }
                }
            case .needsModel:
                if let text {
                    content(text, status: status, stage: nil)
                } else {
                    NeedsModelView()
                }
            case .notStarted:
                centered { SummaryStatusView(entry: entry, status: status) }
            case .noTranscript:
                ContentUnavailableView(
                    "No Summary Yet",
                    systemImage: "text.alignleft",
                    description: Text("Minutes writes the summary once the transcript is ready."),
                )
            case .newerVersion:
                ContentUnavailableView(
                    "Made by a Newer Version of Minutes",
                    systemImage: "arrow.up.circle",
                    description: Text("Update Minutes to read or write this meeting's summary."),
                )
            }
        }
        .task(id: key) {
            let folder = entry.folder
            let key = key
            text = await Task.detached { folder.loadSummary() }.value
            loadedKey = key
        }
        .task(id: center.templatesRevision) {
            let store = center.templateStore
            templates = await Task.detached { store.templates() }.value
        }
        .onChange(of: status) { old, new in
            announce(from: old, to: new)
        }
        .confirmationDialog(
            "Write a new summary with “\(confirmTemplate ?? "")”?",
            isPresented: isConfirmingTemplate,
        ) {
            Button("Regenerate") {
                center.summarize(entry, template: confirmTemplate)
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("The current summary is kept under Previous Versions.")
        }
        .sheet(item: $previous) { version in
            PreviousSummarySheet(version: version)
        }
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: 460)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ markdown: String, status: SummaryStatus, stage _: Summarizer.Stage?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar(status: status)
            if status != .complete, status != .needsModel {
                SummaryStatusView(entry: entry, status: status)
            } else if summary?.namesChanged == true {
                NamesChangedBanner(entry: entry)
            }
            ScrollView {
                MarkdownView(markdown)
                    .padding(.bottom, 20)
                    .accessibilityIdentifier("summaryText")
            }
        }
        .padding(.horizontal, 20)
    }

    private func toolbar(status: SummaryStatus) -> some View {
        let isWorking = status.isUnderWay
        return HStack(spacing: 12) {
            Picker("Template", selection: templateSelection) {
                ForEach(templates) { template in
                    Text(template.name).tag(template.name)
                }
            }
            .fixedSize()
            .disabled(isWorking || !center.hasModel)
            .accessibilityIdentifier("summaryTemplate")
            if let summary, let model = center.modelName(for: summary.model), let date = summary.createdAt {
                ModelLabel(model: model, date: date, isOffNetwork: center.isOffNetwork(summary.model))
            }
            Spacer()
            PreviousVersionsMenu(folder: entry.folder, selection: $previous)
            Button("Copy", systemImage: "doc.on.doc") {
                copy()
            }
            .disabled(text == nil || isWorking)
            .accessibilityIdentifier("summaryCopy")
            Button("Regenerate", systemImage: "arrow.clockwise") {
                center.summarize(entry)
            }
            .disabled(isWorking || !center.hasModel)
            .accessibilityIdentifier("summaryRegenerate")
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
    }

    private var templateSelection: Binding<String> {
        Binding(
            get: { summary?.nextTemplate ?? center.defaultTemplate },
            set: { name in
                guard name != summary?.nextTemplate else {
                    return
                }
                if text == nil {
                    center.summarize(entry, template: name)
                } else {
                    confirmTemplate = name
                }
            },
        )
    }

    private var isConfirmingTemplate: Binding<Bool> {
        Binding(get: { confirmTemplate != nil }, set: {
            if !$0 {
                confirmTemplate = nil
            }
        })
    }

    private func copy() {
        guard let text else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The text is announced once it's done, not word by word.
    private func announce(from old: SummaryStatus, to new: SummaryStatus) {
        guard case .writing = old else {
            return
        }
        switch new {
        case .complete:
            AccessibilityNotification.Announcement("Summary ready").post()
        case .failed:
            AccessibilityNotification.Announcement("Summary failed").post()
        default:
            break
        }
    }
}

/// What a summary is waiting on or doing, with what the user can do about it.
struct SummaryStatusView: View {
    let entry: MeetingEntry
    let status: SummaryStatus

    private var center: SummaryCenter {
        .shared
    }

    var body: some View {
        switch status {
        case let .writing(stage, _):
            let description = SummaryCenter.describe(stage)
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(description)
                    .font(.callout)
                Spacer()
                stopButton
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("summaryProgress")
        case let .waiting(held):
            let message = held
                ? "Summarizing starts after recording and transcribing finish."
                : "Waiting for another summary to finish."
            line(message, systemImage: "clock") {
                stopButton
            }
        case .stopped:
            line("Summarizing stopped.", systemImage: "pause.circle") {
                Button("Resume") {
                    center.summarize(entry)
                }
                .accessibilityIdentifier("summaryResume")
            }
        case let .failed(reason):
            line(reason, systemImage: "exclamationmark.triangle") {
                Button("Try Again") {
                    center.summarize(entry)
                }
                .accessibilityIdentifier("summaryRetry")
            }
        case .notStarted:
            line("This meeting doesn't have a summary yet.", systemImage: "text.alignleft") {
                Button("Summarize") {
                    center.summarize(entry)
                }
                .accessibilityIdentifier("summarySummarize")
            }
        case .needsModel, .noTranscript, .complete, .newerVersion:
            EmptyView()
        }
    }

    private var stopButton: some View {
        Button("Stop") {
            center.queue.stop(entry.id)
        }
        .accessibilityIdentifier("summaryStop")
    }

    private func line(
        _ message: String,
        systemImage: String,
        @ViewBuilder actions: () -> some View,
    ) -> some View {
        HStack(spacing: 10) {
            Label(message, systemImage: systemImage)
                .font(.callout)
            Spacer()
            actions()
        }
        .accessibilityElement(children: .contain)
    }
}

/// Speakers were renamed after the summary was written, and Minutes put the new names in.
private struct NamesChangedBanner: View {
    let entry: MeetingEntry

    var body: some View {
        HStack(spacing: 10) {
            Label("Speaker names changed since this summary was written. The new names are in it.",
                  systemImage: "person.2")
                .font(.callout)
            Spacer()
            Button("Regenerate") {
                SummaryCenter.shared.summarize(entry)
            }
            Button("Dismiss") {
                _ = try? entry.folder.updateSummary { $0?.namesChanged = nil }
                Task {
                    await LibraryStore.shared.refresh()
                }
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summaryNamesChanged")
    }
}

/// Offered when no model is installed, with the default model one click away.
private struct NeedsModelView: View {
    private var center: SummaryCenter {
        .shared
    }

    var body: some View {
        let model = ModelCatalog.recommended()
        ContentUnavailableView {
            Label("Summaries Need a Model", systemImage: "cpu")
        } description: {
            Text("""
            Minutes writes summaries with a model that runs on this Mac, so nothing leaves it. You can \
            also use a server you run, such as LM Studio.
            """)
        } actions: {
            switch center.states[model.id] {
            case let .downloading(progress):
                ProgressView(value: progress?.fraction ?? 0) {
                    Text("Downloading \(model.name)…")
                }
                .frame(width: 240)
            case .paused:
                Button("Resume Downloading \(model.name)") {
                    center.download(model)
                }
            default:
                ModelDownloadButton(
                    model: model,
                    title: "Download \(model.name) (about \(SummaryCenter.bytes(model.approximateBytes)))",
                )
            }
            Button("Other Models and Servers…") {
                RecordingController.shared.openSettings(.aiModels)
            }
            .buttonStyle(.link)
        }
        .accessibilityIdentifier("summaryNeedsModel")
    }
}

/// Who wrote the summary, and a mark when it was a server outside the user's network.
private struct ModelLabel: View {
    let model: String
    let date: Date
    let isOffNetwork: Bool

    var body: some View {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        let written = isOffNetwork
            ? "Written by \(model), outside your network, \(when)"
            : "Written by \(model), \(when)"
        HStack(spacing: 4) {
            if isOffNetwork {
                Image(systemName: "network")
            }
            Text(model)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .help(written)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(written)
        .accessibilityIdentifier("summaryModel")
    }
}
