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
        .library(name: "MinutesFluidAudio", targets: ["MinutesFluidAudio"]),
        .library(name: "MinutesLlama", targets: ["MinutesLlama"]),
        .executable(name: "minutes-audiocheck", targets: ["minutes-audiocheck"]),
        .executable(name: "minutes-diarizecheck", targets: ["minutes-diarizecheck"]),
        .executable(name: "minutes-llmcheck", targets: ["minutes-llmcheck"]),
    ],
    dependencies: [
        // Apache 2.0. Runs Parakeet, the optional engine, and tells speakers apart. An exact version, because it's a
        // young project with frequent releases. Only the diarization trait, which leaves out its prebuilt Rust text
        // library and text-to-speech.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: ["Diarizer"]),
    ],
    targets: [
        // Everything that runs on a real-time audio thread. The SDK marks Swift as unsupported there.
        .target(
            name: "MinutesAudioRT",
            linkerSettings: [.linkedFramework("AVFAudio"), .linkedFramework("CoreAudio")],
        ),
        .target(name: "MinutesAudio", dependencies: ["MinutesAudioRT"]),
        .target(name: "MinutesTranscription", dependencies: ["MinutesStorage"]),
        // Third-party engines get a target of their own, so the core stays free of dependencies. Both FluidAudio
        // engines live here, because they share one switch for FluidAudio's network access.
        .target(
            name: "MinutesFluidAudio",
            dependencies: [
                "MinutesAudio",
                "MinutesDiarization",
                "MinutesStorage",
                "MinutesTranscription",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
        ),
        .target(name: "MinutesDiarization", dependencies: ["MinutesStorage"]),
        .target(name: "MinutesLLM"),
        // MIT. llama.cpp's own prebuilt framework from its v0.9.0 release (build b12110), with Metal built in. Pinned
        // by checksum, so a changed download fails the build instead of running.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12110/llama-b12110-xcframework.zip",
            checksum: "fca702506b04cba11c7f1226056371d16ddfa80e1248da979166a1eec36c415f",
        ),
        // The built-in models. Like FluidAudio, the third-party runtime gets a target of its own.
        .target(name: "MinutesLlama", dependencies: ["MinutesLLM", "llama"]),
        .target(name: "MinutesStorage"),
        // What happens after Stop. No UI imports, so a separate process could run it later.
        .target(
            name: "MinutesPipeline",
            dependencies: [
                "MinutesAudio", "MinutesDiarization", "MinutesLLM", "MinutesStorage", "MinutesTranscription",
            ],
        ),

        // Developer tool for measuring recordings. Not linked into the app.
        .executableTarget(name: "minutes-audiocheck", dependencies: ["MinutesAudio"]),
        .executableTarget(name: "minutes-diarizecheck", dependencies: ["MinutesDiarization", "MinutesFluidAudio"]),
        .executableTarget(name: "minutes-llmcheck", dependencies: ["MinutesLLM", "MinutesLlama", "MinutesStorage"]),

        .testTarget(name: "MinutesAudioRTTests", dependencies: ["MinutesAudioRT"]),
        .testTarget(
            name: "MinutesAudioTests",
            dependencies: ["MinutesAudio", "MinutesAudioRT"],
            resources: [.copy("Fixtures")],
        ),
        .testTarget(name: "MinutesTranscriptionTests", dependencies: ["MinutesTranscription"]),
        .testTarget(name: "MinutesDiarizationTests", dependencies: ["MinutesDiarization", "MinutesStorage"]),
        .testTarget(name: "MinutesLLMTests", dependencies: ["MinutesLLM"]),
        .testTarget(name: "MinutesLlamaTests", dependencies: ["MinutesLlama", "MinutesLLM"]),
        .testTarget(name: "MinutesStorageTests", dependencies: ["MinutesStorage"]),
        .testTarget(name: "MinutesPipelineTests", dependencies: ["MinutesPipeline", "MinutesLLM"]),
        .testTarget(
            name: "MinutesEngineTests",
            dependencies: ["MinutesDiarization", "MinutesTranscription", "MinutesFluidAudio"],
            resources: [.copy("Fixtures")],
        ),
    ],
)
