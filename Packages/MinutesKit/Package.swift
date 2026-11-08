// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "MinutesKit",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "MinutesAudio", targets: ["MinutesAudio"]),
        .library(name: "MinutesTranscription", targets: ["MinutesTranscription"]),
        .library(name: "MinutesDiarization", targets: ["MinutesDiarization"]),
        .library(name: "MinutesLLM", targets: ["MinutesLLM"]),
        .library(name: "MinutesStorage", targets: ["MinutesStorage"]),
        .library(name: "MinutesPipeline", targets: ["MinutesPipeline"]),
        .library(name: "MinutesParakeet", targets: ["MinutesParakeet"]),
        .executable(name: "minutes-audiocheck", targets: ["minutes-audiocheck"]),
    ],
    dependencies: [
        // Apache 2.0. Runs Parakeet, the optional engine. An exact version, because it's a young project with frequent
        // releases. No traits, which leaves out its prebuilt Rust text library and text-to-speech.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: []),
    ],
    targets: [
        // Everything that runs on a real-time audio thread. The SDK marks Swift as unsupported there.
        .target(
            name: "MinutesAudioRT",
            linkerSettings: [.linkedFramework("AVFAudio"), .linkedFramework("CoreAudio")],
        ),
        .target(name: "MinutesAudio", dependencies: ["MinutesAudioRT"]),
        .target(name: "MinutesTranscription", dependencies: ["MinutesStorage"]),
        // Third-party engines get targets of their own, so the core stays free of dependencies.
        .target(
            name: "MinutesParakeet",
            dependencies: [
                "MinutesAudio",
                "MinutesStorage",
                "MinutesTranscription",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
        ),
        .target(name: "MinutesDiarization"),
        .target(name: "MinutesLLM"),
        .target(name: "MinutesStorage"),
        // What happens after Stop. No UI imports, so a separate process could run it later.
        .target(name: "MinutesPipeline", dependencies: ["MinutesAudio", "MinutesStorage", "MinutesTranscription"]),

        // Developer tool for measuring recordings. Not linked into the app.
        .executableTarget(name: "minutes-audiocheck", dependencies: ["MinutesAudio"]),

        .testTarget(name: "MinutesAudioRTTests", dependencies: ["MinutesAudioRT"]),
        .testTarget(
            name: "MinutesAudioTests",
            dependencies: ["MinutesAudio", "MinutesAudioRT"],
            resources: [.copy("Fixtures")],
        ),
        .testTarget(name: "MinutesTranscriptionTests", dependencies: ["MinutesTranscription"]),
        .testTarget(name: "MinutesDiarizationTests", dependencies: ["MinutesDiarization"]),
        .testTarget(name: "MinutesLLMTests", dependencies: ["MinutesLLM"]),
        .testTarget(name: "MinutesStorageTests", dependencies: ["MinutesStorage"]),
        .testTarget(name: "MinutesPipelineTests", dependencies: ["MinutesPipeline"]),
        .testTarget(
            name: "MinutesEngineTests",
            dependencies: ["MinutesTranscription", "MinutesParakeet"],
            resources: [.copy("Fixtures")],
        ),
    ],
)
