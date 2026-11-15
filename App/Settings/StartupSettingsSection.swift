// SPDX-License-Identifier: GPL-3.0-or-later

import os
import ServiceManagement
import SwiftUI

/// Launch at login, the menu bar item and update checks, in Settings › General.
struct StartupSettingsSection: View {
    @Bindable private var menuBar = MenuBarPreferences.shared
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginProblem: String?

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "settings")

    var body: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { loginStatus != .notRegistered && loginStatus != .notFound },
                                                  set: setOpensAtLogin))
                .accessibilityIdentifier("opensAtLogin")
            if loginStatus == .requiresApproval {
                HStack {
                    Text("Allow Minutes in Login Items to finish turning this on.")
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
            if let loginProblem {
                Text(loginProblem)
                    .foregroundStyle(.secondary)
            }
            Toggle("Show in menu bar", isOn: $menuBar.showsIcon)
                .accessibilityIdentifier("showsMenuBarIcon")
            Text("While recording, Minutes is always in the menu bar, so you can stop from there.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
        UpdateSettingsSection()
    }

    private func setOpensAtLogin(_ isOn: Bool) {
        loginProblem = nil
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let error = error as NSError
            Self.logger.error("Login item change failed: \(error.domain, privacy: .public) \(error.code)")
            loginProblem = "Minutes couldn't change this. \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}

private struct UpdateSettingsSection: View {
    private var center: UpdateCenter {
        .shared
    }

    var body: some View {
        switch center.availability {
        case .available:
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { center.checksAutomatically },
                    set: { center.setChecksAutomatically($0) },
                ))
                .accessibilityIdentifier("checksForUpdates")
                LabeledContent("Checks fetch one small file from GitHub and send nothing about you.") {
                    Button("Check Now") {
                        center.checkForUpdates()
                    }
                    .disabled(!center.canCheck)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        case .homebrew:
            Section {
                LabeledContent("Updates") {
                    Text("Homebrew updates Minutes. Run `brew upgrade --cask minutes`.")
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("updatesByHomebrew")
            }
        case .noKey:
            EmptyView()
        }
    }
}
