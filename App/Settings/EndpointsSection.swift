// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import SwiftUI

/// OpenAI-compatible servers: the list, and adding, editing and removing them.
struct EndpointsSection: View {
    /// The endpoint being edited, or a new one.
    @State private var editing: EndpointEditor.Target?

    private var models: AIModelCenter {
        .shared
    }

    var body: some View {
        Section {
            ForEach(models.endpoints) { endpoint in
                EndpointRow(endpoint: endpoint) {
                    editing = .existing(endpoint)
                }
            }
            HStack {
                Spacer()
                Button("Add Server…") {
                    editing = .new
                }
                .accessibilityIdentifier("addEndpoint")
            }
        } header: {
            Text("OpenAI-compatible servers")
        } footer: {
            Text("""
            Use a model you run in llama.cpp, LM Studio or Ollama, on this Mac or another one. Minutes \
            only connects when you test a server or a feature uses it.
            """)
        }
        .sheet(item: $editing) { target in
            EndpointEditor(target: target)
        }
    }
}

private struct EndpointRow: View {
    let endpoint: Endpoint
    let edit: () -> Void

    @State private var isConfirmingRemove = false

    private var models: AIModelCenter {
        .shared
    }

    private var place: String {
        switch endpoint.location {
        case .thisMac: "On this Mac"
        case .localNetwork: "On your network"
        case .internet: "Outside your network"
        case nil: "Not checked yet"
        }
    }

    private var status: String {
        switch models.statuses[endpoint.id] {
        case .checking: "Checking…"
        case let .connected(count): "Connected · \(count == 1 ? "1 model" : "\(count) models")"
        case let .failed(message): message
        case nil: endpoint.models.count == 1 ? "1 model" : "\(endpoint.models.count) models"
        }
    }

    var body: some View {
        LabeledContent {
            HStack {
                Button("Refresh Models", systemImage: "arrow.clockwise") {
                    Task {
                        await models.refresh(endpoint)
                    }
                }
                .labelStyle(.iconOnly)
                .help("Refresh Models")
                .disabled(models.statuses[endpoint.id] == .checking)
                Button("Edit…", action: edit)
                Button("Remove") {
                    isConfirmingRemove = true
                }
            }
        } label: {
            Text(endpoint.name)
            Text("\(endpoint.baseURL.host() ?? endpoint.baseURL.absoluteString) · \(place)")
            Text(status)
                .foregroundStyle(statusIsFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .accessibilityIdentifier("endpointStatus")
        }
        .accessibilityIdentifier("endpoint-\(endpoint.name)")
        .confirmationDialog("Remove \(endpoint.name)?", isPresented: $isConfirmingRemove) {
            Button("Remove", role: .destructive) {
                models.remove(endpoint)
            }
        } message: {
            Text("Its API key is deleted from your keychain. Features that used it go back to the default model.")
        }
    }

    private var statusIsFailure: Bool {
        if case .failed = models.statuses[endpoint.id] {
            return true
        }
        return false
    }
}
