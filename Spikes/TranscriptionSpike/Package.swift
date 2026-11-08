// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

/// The engine comparison for Milestone 3. Results are in docs/TRANSCRIPTION_SPIKE.md.
/// Nothing here is linked into the app, and CI doesn't build it.
let package = Package(
    name: "TranscriptionSpike",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        // No traits, which leaves out the prebuilt Rust text library, TTS and the diarizer.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: []),
        .package(path: "../../Packages/MinutesKit"),
    ],
    targets: [
        .executableTarget(
            name: "transcription-spike",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
        ),
        // The app's own engines, scored the same way.
        .executableTarget(
            name: "engine-check",
            dependencies: [
                .product(name: "MinutesParakeet", package: "MinutesKit"),
                .product(name: "MinutesTranscription", package: "MinutesKit"),
                .product(name: "MinutesStorage", package: "MinutesKit"),
            ],
        ),
    ],
)
