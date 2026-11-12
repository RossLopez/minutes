// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import SwiftUI

/// Adds or edits an OpenAI-compatible server, with Test Connection.
struct EndpointEditor: View {
    enum Target: Identifiable {
        case new
        case existing(Endpoint)

        var id: String {
            switch self {
            case .new: "new"
            case let .existing(endpoint): endpoint.id.uuidString
            }
        }

        var endpoint: Endpoint? {
            if case let .existing(endpoint) = self {
                return endpoint
            }
            return nil
        }
    }

    /// What the last test found, for the address it tested.
    private struct TestResult {
        var address: String
        var connection: EndpointConnection
        var location: NetworkLocation?
    }

    let target: Target

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    /// Typed here. Empty keeps a saved key, unless `removesKey`.
    @State private var apiKey = ""
    @State private var removesKey = false
    @State private var isAutomaticContext = true
    @State private var customContext = Endpoint.defaultContextLength
    @State private var tested: TestResult?
    @State private var status: EndpointStatus?
    @State private var isConfirmingRemote = false
    @State private var pendingLocation: NetworkLocation?

    private var original: Endpoint? {
        target.endpoint
    }

    private var hasSavedKey: Bool {
        original?.usesAPIKey == true && !removesKey
    }

    private var shownName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (URL(string: address)?.host() ?? "Server") : trimmed
    }

    private var location: NetworkLocation? {
        tested?.address == address ? tested?.location : (address == original?.baseURL.absoluteString
            ? original?.location : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("LM Studio"))
                        .accessibilityIdentifier("endpointName")
                    TextField("Base URL", text: $address, prompt: Text(verbatim: "http://localhost:8080/v1"))
                        .accessibilityIdentifier("endpointURL")
                    keyField
                }
                Section {
                    EndpointContextField(
                        isAutomatic: $isAutomaticContext,
                        custom: $customContext,
                        detected: detectedContext,
                    )
                }
                Section {
                    testRow
                    if location == .internet {
                        Label {
                            Text("Meeting transcripts will be sent to \(URL(string: address)?.host() ?? address). "
                                + "Only use a server you trust.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                        .accessibilityIdentifier("endpointRemoteWarning")
                    }
                }
            }
            .formStyle(.grouped)
            buttons
        }
        .frame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog(
            "Send transcripts to \(URL(string: address)?.host() ?? address)?",
            isPresented: $isConfirmingRemote,
        ) {
            Button("Save") {
                finishSaving(location: pendingLocation)
            }
        } message: {
            Text("This server is outside your network. Meeting transcripts are sent to it whenever a feature "
                + "uses it. Only use a server you trust.")
        }
    }

    private var keyField: some View {
        LabeledContent("API key") {
            HStack {
                SecureField("API key", text: $apiKey, prompt: Text(hasSavedKey ? "Saved in your keychain" : "Optional"))
                    .labelsHidden()
                    .accessibilityIdentifier("endpointKey")
                if hasSavedKey, apiKey.isEmpty {
                    Button("Remove") {
                        removesKey = true
                    }
                }
            }
        }
    }

    private var testRow: some View {
        HStack {
            Button("Test Connection") {
                Task {
                    await test()
                }
            }
            .disabled(address.isEmpty || status == .checking)
            .accessibilityIdentifier("endpointTest")
            Group {
                switch status {
                case .checking:
                    ProgressView()
                        .controlSize(.small)
                case let .connected(count):
                    Label(count == 1 ? "Connected · 1 model" : "Connected · \(count) models",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case let .failed(message):
                    Text(message)
                        .foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
            }
            .accessibilityIdentifier("endpointTestResult")
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(original == nil ? "Add" : "Save") {
                Task {
                    await save()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(address.isEmpty || status == .checking)
            .accessibilityIdentifier("endpointSave")
        }
        .padding(16)
    }

    /// For the first model, which is what most servers have.
    private var detectedContext: Int? {
        let connection = tested?.address == address ? tested?.connection : nil
        let lengths = connection?.contextLengths ?? original?.detectedContextLengths ?? [:]
        let models = connection?.models ?? original?.models ?? []
        return models.first.flatMap { lengths[$0] }
    }

    private func load() {
        guard let original else {
            return
        }
        name = original.name
        address = original.baseURL.absoluteString
        isAutomaticContext = original.contextLength == nil
        customContext = original.contextLength ?? original.detectedContextLengths.values.first
            ?? Endpoint.defaultContextLength
    }

    private var keyForRequests: String? {
        apiKey.isEmpty ? (hasSavedKey ? original.flatMap(AIModelCenter.shared.apiKey) : nil) : apiKey
    }

    private func test() async {
        guard case let .success(url) = EndpointAddressProblem.check(address, location: nil) else {
            status = .failed(EndpointAddressProblem.invalid.message)
            return
        }
        status = .checking
        let typed = address
        do {
            let (connection, location) = try await AIModelCenter.connect(to: url, apiKey: keyForRequests,
                                                                         name: shownName)
            // The address that worked, with its `/v1` if it gained one.
            address = connection.baseURL.absoluteString
            tested = TestResult(address: address, connection: connection, location: location)
            status = .connected(models: connection.models.count)
        } catch {
            if address == typed {
                status = .failed(AIModelCenter.describe(error))
            }
        }
    }

    private func save() async {
        guard case let .success(url) = EndpointAddressProblem.check(address, location: nil) else {
            status = .failed(EndpointAddressProblem.invalid.message)
            return
        }
        var location = location
        if location == nil {
            location = await NetworkLocator.location(of: url)
        }
        if case let .failure(problem) = EndpointAddressProblem.check(address, location: location) {
            status = .failed(problem.message)
            return
        }
        // Said once more before it's saved, since every later summary goes there.
        let isConfirmed = original?.location == .internet && original?.baseURL == url
        if location != .thisMac, location != .localNetwork, !isConfirmed {
            pendingLocation = location
            isConfirmingRemote = true
            return
        }
        finishSaving(location: location)
    }

    private func finishSaving(location: NetworkLocation?) {
        guard case let .success(url) = EndpointAddressProblem.check(address, location: location) else {
            return
        }
        var endpoint = original ?? Endpoint(name: shownName, baseURL: url)
        endpoint.name = shownName
        let isSameAddress = endpoint.baseURL == url
        endpoint.baseURL = url
        endpoint.contextLength = isAutomaticContext ? nil : max(1024, customContext)
        endpoint.location = location ?? .internet
        if let tested, tested.address == address {
            endpoint.apply(tested.connection, location: location)
        } else if !isSameAddress {
            endpoint.models = []
            endpoint.detectedContextLengths = [:]
        }
        let keyChange: String? = apiKey.isEmpty ? (removesKey ? "" : nil) : apiKey
        do {
            try AIModelCenter.shared.save(endpoint, apiKey: keyChange)
        } catch {
            status = .failed("Minutes couldn't save the API key in your keychain.")
            return
        }
        if tested?.address != address {
            Task {
                await AIModelCenter.shared.refresh(endpoint)
            }
        }
        dismiss()
    }
}

/// Automatic, which says what the server reported, or a number of tokens.
private struct EndpointContextField: View {
    @Binding var isAutomatic: Bool
    @Binding var custom: Int
    let detected: Int?

    var body: some View {
        Picker("Context length", selection: $isAutomatic) {
            Text(detected.map { "Automatic (\($0.formatted()) tokens, from the server)" }
                ?? "Automatic (\(Endpoint.defaultContextLength.formatted()) tokens, assumed)")
                .tag(true)
            Text("Custom").tag(false)
        }
        .accessibilityIdentifier("endpointContextMode")
        if !isAutomatic {
            TextField("Tokens", value: $custom, format: .number)
                .accessibilityIdentifier("endpointContext")
        }
        if isAutomatic, detected == nil {
            Text("""
            The server didn't say how much it reads. Set this to the server's context length. For \
            Ollama, that's the model's num_ctx.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
