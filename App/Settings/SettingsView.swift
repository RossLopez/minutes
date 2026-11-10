// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var selection = SettingsTab.general

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    switch tab {
                    case .general:
                        GeneralSettingsTab()
                    case .recording:
                        RecordingSettingsTab()
                    case .permissions:
                        PermissionsSettingsTab()
                    case .about:
                        AboutSettingsTab()
                    case .storage:
                        StorageSettingsTab()
                    case .transcription:
                        TranscriptionSettingsTab()
                    case .aiModels:
                        AIModelsSettingsTab()
                    case .summaryTemplates:
                        SummaryTemplatesSettingsTab()
                    }
                }
            }
        }
        .frame(width: 720, height: 420)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    static let storageKey = "settings.selectedTab"

    case general
    case recording
    case transcription
    case aiModels
    case summaryTemplates
    case permissions
    case storage
    case about

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .aiModels: "AI Models"
        case .summaryTemplates: "Summary Templates"
        case .permissions: "Permissions"
        case .storage: "Storage"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .transcription: "text.quote"
        case .aiModels: "cpu"
        case .summaryTemplates: "doc.text"
        case .permissions: "hand.raised"
        case .storage: "internaldrive"
        case .about: "info.circle"
        }
    }
}
