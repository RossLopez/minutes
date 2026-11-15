// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesLLM
import SwiftUI

/// What a new user sees once: who they are, permissions, a model, the consent note. One screen per
/// step, and every step past the welcome can be skipped.
struct FirstRunView: View {
    enum Step: Hashable {
        case welcome
        case name
        case permissions
        case model
        case consent
        case done

        var isSkippable: Bool {
            self != .welcome && self != .done
        }
    }

    static let completedKey = "firstRun.completed"

    static var isForcedForTesting: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["MINUTES_FIRST_RUN"] == "1"
        #else
            false
        #endif
    }

    let steps: [Step]
    let onFinish: () -> Void

    @State private var index = 0
    @State private var choice = FirstRunChoice()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The consent step is left out for anyone who saw it before this flow existed, and the model
    /// step when a built-in model is already there.
    static func steps(consentShown: Bool, hasModel: Bool) -> [Step] {
        var steps: [Step] = [.welcome, .name, .permissions]
        if !hasModel {
            steps.append(.model)
        }
        if !consentShown {
            steps.append(.consent)
        }
        steps.append(.done)
        return steps
    }

    private var step: Step {
        steps[index]
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .id(step)
                .transition(reduceMotion ? .opacity : .push(from: .trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 32)
                .padding(.top, 28)
            Divider()
            buttons
                .padding(16)
        }
        .frame(width: 580, height: 500)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .name: NameStep()
        case .permissions: PermissionsStep()
        case .model: ModelStep(choice: $choice)
        case .consent: ConsentStep()
        case .done: DoneStep(choice: $choice)
        }
    }

    private var buttons: some View {
        HStack {
            if index > 0 {
                Button("Back") {
                    move(by: -1)
                }
                .accessibilityIdentifier("firstRunBack")
            }
            Spacer()
            if step.isSkippable {
                Button("Skip") {
                    if step == .model {
                        choice.model = nil
                    }
                    move(by: 1)
                }
                .accessibilityIdentifier("firstRunSkip")
            }
            Button(continueTitle) {
                if step == .done {
                    finish()
                } else {
                    move(by: 1)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("firstRunContinue")
        }
    }

    private var continueTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .done: "Start Using Minutes"
        default: "Continue"
        }
    }

    private func move(by offset: Int) {
        withAnimation(reduceMotion ? nil : .snappy) {
            index = min(max(index + offset, 0), steps.count - 1)
        }
    }

    private func finish() {
        if let model = choice.model {
            AIModelCenter.shared.defaultChoice = .builtIn(model.id)
            if SummaryCenter.shared.states[model.id] == .notInstalled || SummaryCenter.shared.states[model.id] == nil {
                SummaryCenter.shared.download(model)
            }
        }
        UpdateCenter.shared.setChecksAutomatically(choice.checksForUpdates)
        onFinish()
    }
}

/// What the steps decide, applied when the flow finishes.
struct FirstRunChoice {
    /// Nil when skipped.
    var model: CatalogModel? = ModelCatalog.recommended()
    var checksForUpdates = true
}

/// A step's symbol, title and explanation.
struct FirstRunHeader: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
