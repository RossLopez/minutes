// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesDiarization
import MinutesFluidAudio

// Runs the speaker diarizer on one file and writes what it found, so accuracy, speed and memory
// can be measured against labelled meetings. A developer tool, not part of the app. It never
// downloads: point it at a folder that already holds the model.
//
//   minutes-diarizecheck <models folder> <audio> <output.json> [--batch <windows>] [--remeasure]
//
// --remeasure also measures each speaker's voice again from all of their turns, the way the app
// does when someone is named with speaker memory on.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// The peak footprint, as Activity Monitor counts it. Unlike the resident size, it leaves out the
/// mapped audio file, whose pages the system can drop at any time.
func peakMemoryMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else {
        return 0
    }
    return Double(info.ledger_phys_footprint_peak) / 1_048_576
}

struct Report: Encodable {
    var audioSeconds: Double
    var diarizeSeconds: Double
    var remeasureSeconds: Double?
    var peakMemoryMB: Double
    var batchSize: Int
    var turns: [SpeakerTurn]
    var embeddings: [String: [Float]]
    var remeasured: [String: [Float]]?
}

var arguments = Array(CommandLine.arguments.dropFirst())
var batchSize = 8
var remeasure = false
if let index = arguments.firstIndex(of: "--batch") {
    guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
        fail("--batch needs a number of windows")
    }
    batchSize = value
    arguments.removeSubrange(index ... index + 1)
}

if let index = arguments.firstIndex(of: "--remeasure") {
    remeasure = true
    arguments.remove(at: index)
}

guard arguments.count == 3 else {
    fail("Usage: minutes-diarizecheck <models folder> <audio> <output.json> [--batch <windows>] [--remeasure]")
}

let models = URL(fileURLWithPath: arguments[0], isDirectory: true)
let audio = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let work = output.deletingLastPathComponent()
    .appendingPathComponent(".diarizecheck-\(UUID().uuidString)", isDirectory: true)

let diarizer = FluidDiarizer(modelsFolder: { models }, batchSize: batchSize)
guard await diarizer.modelStatus() == .installed else {
    fail("No diarizer model in \(models.path)")
}

do {
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    let start = Date()
    let result = try await diarizer.diarize(audio: audio, workFolder: work) { _ in }
    let diarizeSeconds = Date().timeIntervalSince(start)
    let audioSeconds = result.turns.map(\.end).max() ?? 0

    var remeasured: [String: [Float]]?
    var remeasureSeconds: Double?
    if remeasure {
        let started = Date()
        var vectors: [String: [Float]] = [:]
        for speaker in result.speakers {
            let spans = result.turns.filter { $0.speaker == speaker }.map { $0.start ... $0.end }
            vectors[speaker] = try await diarizer.embedding(audio: audio, spans: spans, workFolder: work)
        }
        remeasured = vectors
        remeasureSeconds = Date().timeIntervalSince(started)
    }

    let report = Report(
        audioSeconds: audioSeconds,
        diarizeSeconds: diarizeSeconds,
        remeasureSeconds: remeasureSeconds,
        peakMemoryMB: peakMemoryMB(),
        batchSize: batchSize,
        turns: result.turns,
        embeddings: result.embeddings,
        remeasured: remeasured,
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(report).write(to: output)
    print(
        "\(audio.lastPathComponent): \(result.speakers.count) speakers, \(result.turns.count) turns, "
            + String(format: "%.1f s (%.0f× real time), peak %.0f MB", diarizeSeconds,
                     audioSeconds / max(diarizeSeconds, 0.001), peakMemoryMB()),
    )
} catch {
    fail("Failed: \(error)")
}
