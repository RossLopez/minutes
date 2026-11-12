// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import SwiftUI

/// The default model, or one feature's. A feature's picker also offers "Same as default".
struct ModelChoicePicker: View {
    let title: String
    /// Nil for the default model's picker.
    let feature: AIFeature?

    private var models: AIModelCenter {
        .shared
    }

    var body: some View {
        if let feature {
            Picker(title, selection: Binding(
                get: { models.choice(for: feature) },
                set: { models.setChoice($0, for: feature) },
            )) {
                Text("Same as default").tag(ModelChoice?.none)
                Divider()
                ModelChoiceOptions(current: models.choice(for: feature)) { Optional($0) }
            }
            .accessibilityIdentifier("model-\(feature.rawValue)")
        } else {
            Picker(title, selection: Binding(
                get: { models.defaultChoice },
                set: { models.defaultChoice = $0 },
            )) {
                ModelChoiceOptions(current: models.defaultChoice) { $0 }
            }
            .accessibilityIdentifier("defaultModel")
        }
    }
}

/// Downloaded built-in models, then each endpoint's, under its name.
private struct ModelChoiceOptions<Tag: Hashable>: View {
    let current: ModelChoice?
    let tag: (ModelChoice) -> Tag

    private var installed: [CatalogModel] {
        ModelCatalog.all.filter { SummaryCenter.shared.states[$0.id] == .installed }
    }

    private var endpoints: [Endpoint] {
        AIModelCenter.shared.endpoints
    }

    private var listed: Set<ModelChoice> {
        Set(installed.map { .builtIn($0.id) })
            .union(endpoints.flatMap { endpoint in endpoint.models.map { .endpoint(endpoint.id, model: $0) } })
    }

    var body: some View {
        Section("Built In") {
            if installed.isEmpty {
                Text("None downloaded")
                    .selectionDisabled()
            }
            ForEach(installed) { model in
                Text(model.name).tag(tag(.builtIn(model.id)))
            }
        }
        ForEach(endpoints) { endpoint in
            Section(endpoint.isOffNetwork ? "\(endpoint.name) · Outside your network" : endpoint.name) {
                if endpoint.models.isEmpty {
                    Text("No models found yet")
                        .selectionDisabled()
                }
                ForEach(endpoint.models, id: \.self) { model in
                    Text(Endpoint.displayName(ofModel: model)).tag(tag(.endpoint(endpoint.id, model: model)))
                }
            }
        }
        // Kept selectable, so a choice that isn't available now still shows as chosen.
        if let current, !listed.contains(current) {
            Divider()
            Text("\(AIModelCenter.shared.name(of: current)) (not available)").tag(tag(current))
        }
    }
}
