// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesAudio

/// A temporary folder removed when the test ends.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MinutesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}

/// The checked-in signal: two seconds of `AudioAnalysis.makeAlignmentSignal` at 48 kHz.
enum Fixture {
    static var url: URL {
        get throws {
            guard let url = Bundle.module.url(
                forResource: "alignment-2s",
                withExtension: "caf",
                subdirectory: "Fixtures",
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return url
        }
    }

    static func samples() throws -> [Float] {
        try AudioAnalysis.read(url).samples
    }
}

func writeCAF(_ samples: [Float], to url: URL) throws {
    let writer = try CAFTrackWriter(url: url)
    try samples.withUnsafeBufferPointer { try writer.append($0) }
    writer.close()
}

func sine(frequency: Double, rate: Double, frames: Int, amplitude: Float = 0.25) -> [Float] {
    (0 ..< frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
}
