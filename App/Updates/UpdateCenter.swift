// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import os
import Sparkle

/// Checks for and installs updates with Sparkle, when this copy of Minutes should update itself.
@MainActor @Observable
final class UpdateCenter {
    enum Availability: Equatable {
        case available
        /// Built without the key that signs updates, like a fork or a Debug build.
        case noKey
        /// Installed by the Homebrew cask, which updates it.
        case homebrew
    }

    static let shared = UpdateCenter()
    nonisolated static let caskToken = "minutes"

    let availability: Availability
    private(set) var canCheck = false
    /// Mirrors Sparkle's setting, which it keeps in the app's defaults.
    private(set) var checksAutomatically = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private static let logger = Logger(subsystem: "io.github.rosslopez.minutes", category: "updates")

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        availability = Self.availability(publicKey: key, isHomebrewInstall: Self.isHomebrewInstall())
        controller = availability == .available
            ? SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    nonisolated static func availability(publicKey: String?, isHomebrewInstall: Bool) -> Availability {
        guard let publicKey, !publicKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .noKey
        }
        return isHomebrewInstall ? .homebrew : .available
    }

    /// The cask keeps a folder in the Caskroom for as long as it's installed.
    nonisolated static func isHomebrewInstall(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> Bool {
        var prefixes = ["/opt/homebrew", "/usr/local"]
        if let prefix = environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
            prefixes.insert(prefix, at: 0)
        }
        return prefixes.contains { fileExists("\($0)/Caskroom/\(caskToken)") }
    }

    /// Starts the updater. Called once at launch.
    func start() {
        guard let controller else {
            // A local, because SwiftFormat versions disagree about `self` in a log message.
            let reason = String(describing: availability)
            Self.logger.info("Updates off: \(reason, privacy: .public)")
            return
        }
        controller.startUpdater()
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in
                UpdateCenter.shared.canCheck = value
            }
        }
    }

    func setChecksAutomatically(_ value: Bool) {
        guard let controller else {
            return
        }
        controller.updater.automaticallyChecksForUpdates = value
        checksAutomatically = value
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
