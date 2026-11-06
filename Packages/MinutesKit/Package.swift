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
        .executable(name: "minutes-audiocheck", targets: ["minutes-audiocheck"]),
    ],
    targets: [
        // Everything that runs on a real-time audio thread. The SDK marks Swift as unsupported there.
        .target(
            name: "MinutesAudioRT",
            linkerSettings: [.linkedFramework("AVFAudio"), .linkedFramework("CoreAudio")],
        ),
        .target(name: "MinutesAudio", dependencies: ["MinutesAudioRT"]),
        .target(name: "MinutesTranscription"),
        .target(name: "MinutesDiarization"),
        .target(name: "MinutesLLM"),
        .target(name: "MinutesStorage"),

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
    ],
)
