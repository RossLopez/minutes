// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesLLM
import SwiftUI

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Welcome to Minutes")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("""
            Minutes records your meetings from your Mac's microphone and audio, then transcribes and \
            summarizes them for you.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                WelcomePoint(systemImage: "lock.laptopcomputer",
                             text: "Recordings, transcripts and notes stay on this Mac.")
                WelcomePoint(systemImage: "person.crop.circle.badge.xmark", text: "No accounts and no sign-in.")
                WelcomePoint(systemImage: "video.slash",
                             text: "It never joins your calls. It only hears what your Mac hears.")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 440)
    }
}

private struct WelcomePoint: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28)
        }
    }
}

struct NameStep: View {
    @AppStorage(SpeakerPreferences.yourNameKey) private var yourName = NSFullUserName()
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FirstRunHeader(
                systemImage: "person.wave.2",
                title: "What's your name?",
                message: """
                Transcripts show it for what your microphone hears, and other people's voices get names \
                you choose later. It stays on this Mac.
                """,
            )
            TextField("Your name", text: $yourName, prompt: Text("Me"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 320)
                .focused($isFocused)
                .accessibilityIdentifier("firstRunName")
        }
        .onAppear {
            isFocused = true
        }
    }
}

struct PermissionsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FirstRunHeader(
                systemImage: "hand.raised",
                title: "Allow recording",
                message: """
                Minutes needs these to record a meeting. You can change them any time in \
                Settings › Permissions.
                """,
            )
            Form {
                PermissionRows()
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
        }
        .task {
            await PermissionsModel.shared.refresh(includingSystemAudio: true)
        }
    }
}

struct ModelStep: View {
    @Binding var choice: FirstRunChoice

    private var models: [CatalogModel] {
        ModelCatalog.all.filter { !$0.isAdvanced || $0.fitsMemory() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FirstRunHeader(
                systemImage: "sparkles",
                title: "Choose a model for summaries",
                message: """
                Summaries, notes cleanup and chat run on a model that downloads from Hugging Face and \
                runs on this Mac. Recording and transcripts work without one.
                """,
            )
            VStack(spacing: 6) {
                ForEach(models) { model in
                    ModelOption(model: model, isSelected: choice.model?.id == model.id) {
                        choice.model = model
                    }
                }
            }
            Text("It downloads in the background. You can change models in Settings › AI Models.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ModelOption: View {
    let model: CatalogModel
    let isSelected: Bool
    let select: () -> Void

    private var detail: String {
        let size = SummaryCenter.bytes(model.approximateBytes)
        let note = switch model.id {
        case ModelCatalog.gemma12B.id: "Best summaries and chat"
        case ModelCatalog.gemmaE4B.id: "Lighter, and fast on 8 GB Macs"
        case "gemma-4-e2b": "The smallest"
        default: "For Macs with 32 GB of memory or more"
        }
        return "\(note) · about \(size)"
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !model.fitsMemory() {
                        Label("This Mac may not have enough memory for it.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("firstRunModel-\(model.id)")
    }
}

struct ConsentStep: View {
    var body: some View {
        FirstRunHeader(
            systemImage: "person.2.wave.2",
            title: "Recording consent",
            message: """
            Some places require everyone's consent to record a conversation. Getting it is up to you. \
            If you turn on Remember voices, the same goes for saving the voices of the people you name.
            """,
        )
    }
}

struct DoneStep: View {
    @Binding var choice: FirstRunChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FirstRunHeader(
                systemImage: "checkmark.circle",
                title: "You're ready",
                message: """
                Click Record in the toolbar or the menu bar, or press \(HotKeyShortcut.load().display) \
                anywhere, when a meeting starts. Minutes transcribes it when you stop.
                """,
            )
            if let model = choice.model {
                Label("\(model.name) will download in the background.", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
            if UpdateCenter.shared.availability == .available {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Check for updates automatically", isOn: $choice.checksForUpdates)
                        .accessibilityIdentifier("firstRunUpdates")
                    Text("Checking fetches one small file from GitHub and sends nothing about you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
