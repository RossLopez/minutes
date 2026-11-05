// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let moduleNames = [
    "MinutesAudio",
    "MinutesTranscription",
    "MinutesDiarization",
    "MinutesLLM",
    "MinutesStorage",
]

let package = Package(
    name: "MinutesKit",
    platforms: [.macOS(.v27)],
    products: moduleNames.map { .library(name: $0, targets: [$0]) },
    targets: moduleNames.flatMap { name -> [Target] in
        [
            .target(name: name),
            .testTarget(name: "\(name)Tests", dependencies: [.target(name: name)]),
        ]
    },
)
