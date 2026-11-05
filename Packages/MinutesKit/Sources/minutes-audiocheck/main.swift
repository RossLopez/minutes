// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesAudio

// Measures a recording, so "no echo" is a number. A developer tool, not part of the app.
//
//   minutes-audiocheck <meeting folder>
//   minutes-audiocheck --make-signal <seconds> <output.caf>

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func format(_ value: some BinaryFloatingPoint, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", Double(value))
}

func audioFile(named name: String, in folder: URL) -> URL? {
    ["m4a", "caf"]
        .map { folder.appendingPathComponent("audio/\(name).\($0)") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--make-signal" {
    guard arguments.count == 3, let seconds = Double(arguments[1]) else {
        fail("Usage: minutes-audiocheck --make-signal <seconds> <output.caf>")
    }
    let samples = AudioAnalysis.makeAlignmentSignal(seconds: seconds, sampleRate: 48000, amplitude: 0.1, seed: 42)
    let url = URL(fileURLWithPath: arguments[2])
    let writer = try CAFTrackWriter(url: url)
    try samples.withUnsafeBufferPointer { try writer.append($0) }
    writer.close()
    print("Wrote \(format(seconds)) s of test signal to \(url.path)")
    exit(0)
}

guard arguments.count == 1 else {
    fail("Usage: minutes-audiocheck <meeting folder>")
}

let folder = URL(fileURLWithPath: arguments[0])
guard let micURL = audioFile(named: "mic-raw", in: folder),
      let systemURL = audioFile(named: "system", in: folder)
else {
    fail("No mic-raw and system audio in \(folder.path)/audio")
}

let mic = try AudioAnalysis.read(micURL)
let system = try AudioAnalysis.read(systemURL)

for (name, track) in [("mic", mic), ("system", system)] {
    let level = AudioAnalysis.level(of: track.samples, sampleRate: track.sampleRate)
    let duration = format(level.durationSeconds, 2)
    print("\(name): \(duration) s, peak \(format(level.peak, 4)), RMS \(format(level.rmsDecibels)) dBFS")
}

let lengthDifference = abs(Double(mic.samples.count) - Double(system.samples.count))
print("duration difference: \(format(lengthDifference / mic.sampleRate * 1000)) ms")

// Measured in windows across the recording, so any build-up over time shows.
let rate = mic.sampleRate
let windowFrames = Int(10 * rate)
let usable = min(mic.samples.count, system.samples.count)
let windows = max(1, min(5, usable / windowFrames))
let spacing = windows > 1 ? (usable - windowFrames) / (windows - 1) : 0
print("window      lag ms  correlation  echo dB")
for index in 0 ..< windows {
    let start = index * spacing
    let end = min(start + windowFrames, usable)
    guard let leak = AudioAnalysis.measureLeak(
        mic: mic.samples[start ..< end],
        system: system.samples[start ..< end],
        sampleRate: rate,
    ) else {
        print("\(format(Double(start) / rate))s: not enough audio")
        continue
    }
    let time = format(Double(start) / rate).padding(toLength: 10, withPad: " ", startingAt: 0)
    print("\(time)  \(format(leak.lagMilliseconds))  \(format(leak.correlation, 3))  \(format(leak.echoDecibels))")
}
