// SPDX-License-Identifier: GPL-3.0-or-later

// Runs the app's own engines on a file and writes the same JSON as transcription-spike, for score.py.
//
//   engine-check apple|parakeet <audio> <out.json> [--terms file] [--models folder]

import AVFoundation
import Foundation
import MinutesParakeet
import MinutesStorage
import MinutesTranscription

func peakFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
}

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).map { arguments[$0 + 1] }
}

let audio = URL(fileURLWithPath: arguments[2])
let out = URL(fileURLWithPath: arguments[3])
let terms = try option("--terms").map { try Vocabulary.parse(String(contentsOfFile: $0, encoding: .utf8)) } ?? []
let models = URL(fileURLWithPath: option("--models") ?? ".", isDirectory: true)
let engine: any TranscriptionEngine = arguments[1] == "apple" ? AppleSpeechEngine() : ParakeetEngine { models }

let work = FileManager.default.temporaryDirectory.appendingPathComponent("engine-check-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let file = try AVAudioFile(forReading: audio)
let seconds = Double(file.length) / file.fileFormat.sampleRate
let start = ContinuousClock.now
let words = try await engine.transcribe(audio: audio, vocabulary: terms, workFolder: work) { _ in }
let elapsed = start.duration(to: .now).components
let taken = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
let text = words.map(\.text).joined(separator: " ")
let result: [String: Any] = [
    "text": text,
    "words": words.map { ["text": $0.text, "start": $0.start, "end": $0.end] },
    "notes": [engine.modelName],
    "audioSeconds": seconds,
    "transcribeSeconds": taken,
    "prepareSeconds": 0,
    "peakFootprintMB": peakFootprintMB(),
]
try JSONSerialization.data(withJSONObject: result).write(to: out)
print(
    "\(engine.id): \(String(format: "%.1f", taken)) s, \(String(format: "%.0f", seconds / taken))x, peak \(String(format: "%.0f", peakFootprintMB())) MB, \(words.count) words",
)
