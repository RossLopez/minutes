// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

struct PermissionsSettingsTab: View {
    private let model = PermissionsModel.shared

    var body: some View {
        Form {
            PermissionRow(
                title: "Microphone",
                systemImage: "mic",
                reason: "Records your voice during a meeting.",
                status: model.microphone,
                request: { _ = await model.requestMicrophoneIfNeeded() },
                openSettings: { model.openSystemSettings(.microphone) },
            )
            PermissionRow(
                title: "System Audio Recording",
                systemImage: "speaker.wave.2",
                reason: "Records what other people say, from the audio your Mac plays.",
                status: model.systemAudio,
                request: { _ = await model.checkSystemAudio() },
                openSettings: { model.openSystemSettings(.systemAudio) },
                checkAgain: { _ = await model.checkSystemAudio() },
            )
            PermissionRow(
                title: "Notifications",
                systemImage: "bell",
                reason: "Tells you when a meeting has finished processing.",
                status: model.notifications,
                request: { await model.requestNotifications() },
                openSettings: { model.openSystemSettings(.notifications) },
            )
        }
        .formStyle(.grouped)
        .task {
            await model.refresh(includingSystemAudio: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refresh(includingSystemAudio: true)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let systemImage: String
    let reason: String
    let status: PermissionStatus
    let request: () async -> Void
    let openSettings: () -> Void
    var checkAgain: (() async -> Void)?

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                PermissionBadge(status: status)
                switch status {
                case .notRequested:
                    Button("Request…") {
                        Task { await request() }
                    }
                case .unknown:
                    if let checkAgain {
                        Button("Check Again") {
                            Task { await checkAgain() }
                        }
                    }
                    Button("Open Settings…", action: openSettings)
                case .granted, .denied:
                    Button("Open Settings…", action: openSettings)
                case .checking:
                    EmptyView()
                }
            }
        } label: {
            Label {
                Text(title)
                Text(reason)
            } icon: {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct PermissionBadge: View {
    let status: PermissionStatus

    private var title: String {
        switch status {
        case .granted: "Granted"
        case .notRequested: "Not requested"
        case .denied: "Denied"
        case .unknown: "Unknown"
        case .checking: "Checking…"
        }
    }

    private var color: Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .unknown: .orange
        case .notRequested, .checking: .secondary
        }
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: .capsule)
    }
}
