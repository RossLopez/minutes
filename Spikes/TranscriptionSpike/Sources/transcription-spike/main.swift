// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Darwin
import FluidAudio
import Foundation
import Speech
import WhisperKit

// Runs one engine on one audio file and writes what it heard, with timings and memory, as JSON.
// Each run is its own process, so one engine's memory can't count against another.
//
//   transcription-spike --engine apple|whisper|parakeet [--model name] --audio file --out file.json
//                       [--terms file] [--models folder]

struct Word: Codable {
    var text: String
    var start: Double
    var end: Double
}

struct Output: Codable {
    var engine: String
    var model: String
    var biased: Bool
    var audioSeconds: Double
    var prepareSeconds: Double
    var transcribeSeconds: Double
    var peakFootprintMB: Double
    var text: String
    var words: [Word]
    var notes: [String]
}

struct Heard {
    var text: String
    var words: [Word]
    var notes: [String] = []
}

struct Arguments {
    let engine: String
    let model: String?
    let audio: URL
    let out: URL
    let terms: [VocabularyEntry]
    let models: URL?

    init() throws {
        var values: [String: String] = [:]
        var index = 1
        while index + 1 < CommandLine.arguments.count {
            values[CommandLine.arguments[index]] = CommandLine.arguments[index + 1]
            index += 2
        }
        guard let engine = values["--engine"], let audio = values["--audio"], let out = values["--out"] else {
            throw SpikeError.usage
        }
        self.engine = engine
        model = values["--model"]
        self.audio = URL(fileURLWithPath: audio)
        self.out = URL(fileURLWithPath: out)
        models = values["--models"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        terms = try values["--terms"].map { try VocabularyEntry.load(URL(fileURLWithPath: $0)) } ?? []
    }
}

/// A line like `Tanium = tan ium, tannium`.
struct VocabularyEntry {
    let term: String
    let variants: [String]

    static func load(_ url: URL) throws -> [VocabularyEntry] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                let variants = parts.count > 1
                    ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    : []
                return VocabularyEntry(term: parts[0], variants: variants)
            }
    }
}

enum SpikeError: Error {
    case usage
    case unknownEngine(String)
    case unsupportedLocale
    case missingTokenizer
}

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

func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
}

// MARK: - Apple

func runApple(_ arguments: Arguments, prepared: inout Double) async throws -> Heard {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) else {
        throw SpikeError.unsupportedLocale
    }
    let start = ContinuousClock.now
    let useDictation = arguments.model == "dictation"
    let speech = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange, .transcriptionConfidence],
    )
    let dictation = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
    let module: any SpeechModule = useDictation ? dictation : speech
    var notes: [String] = []
    let status = await AssetInventory.status(forModules: [module])
    notes.append("asset status before: \(status)")
    if status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        try await request.downloadAndInstall()
    }
    let options = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .whileInUse,
        ignoresResourceLimits: true,
    )
    // Given at creation rather than through setContext, so it's in place before any audio.
    let context = AnalysisContext()
    if !arguments.terms.isEmpty {
        context.contextualStrings[.general] = arguments.terms.map(\.term)
        notes.append("contextualStrings set: \(arguments.terms.count)")
    }
    let file = try AVAudioFile(forReading: arguments.audio)
    prepared = seconds(since: start)

    let collector = Task {
        var pieces: [AttributedString] = []
        if useDictation {
            for try await result in dictation.results {
                pieces.append(result.text)
            }
        } else {
            for try await result in speech.results {
                pieces.append(result.text)
            }
        }
        var words: [Word] = []
        var text = ""
        for piece in pieces {
            text += String(piece.characters)
            for run in piece.runs {
                if let range = run.audioTimeRange {
                    words.append(Word(
                        text: String(piece[run.range].characters),
                        start: range.start.seconds,
                        end: range.end.seconds,
                    ))
                }
            }
        }
        return Heard(text: text, words: words)
    }
    let analyzer = try await SpeechAnalyzer(
        inputAudioFile: file,
        modules: [module],
        options: options,
        analysisContext: context,
        finishAfterFile: true,
    )
    _ = analyzer
    var heard = try await collector.value
    heard.notes = notes
    return heard
}

// MARK: - WhisperKit

func runWhisper(_ arguments: Arguments, prepared: inout Double) async throws -> Heard {
    let start = ContinuousClock.now
    let model = arguments.model ?? "large-v3-v20240930_turbo"
    let config = WhisperKitConfig(model: model, downloadBase: arguments.models, verbose: false, logLevel: .error)
    let pipe = try await WhisperKit(config)
    if pipe.tokenizer == nil {
        try await pipe.loadModels()
    }
    prepared = seconds(since: start)

    var options = DecodingOptions(
        verbose: false,
        task: .transcribe,
        language: "en",
        temperature: 0,
        usePrefillPrompt: true,
        detectLanguage: false,
        wordTimestamps: true,
        chunkingStrategy: ProcessInfo.processInfo.environment["SPIKE_WHISPER_CHUNKING"] == "none" ? ChunkingStrategy
            .none : .vad,
    )
    var notes: [String] = []
    if !arguments.terms.isEmpty {
        guard let tokenizer = pipe.tokenizer else {
            throw SpikeError.missingTokenizer
        }
        let prompt = " " + arguments.terms.map(\.term).joined(separator: ", ") + "."
        let tokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        options.promptTokens = tokens
        notes.append("prompt tokens: \(tokens.count)")
    }
    let results = try await pipe.transcribe(audioPath: arguments.audio.path, decodeOptions: options)
    var words: [Word] = []
    var text = ""
    for result in results {
        text += result.text + " "
        for segment in result.segments {
            for word in segment.words ?? [] {
                words.append(Word(text: word.word, start: Double(word.start), end: Double(word.end)))
            }
        }
    }
    return Heard(text: text, words: words, notes: notes)
}

// MARK: - Parakeet

func parakeetVersion(_ name: String?) -> AsrModelVersion {
    switch name {
    case "v3": .v3
    case "ultra": .ultra
    default: .v2
    }
}

func runParakeet(_ arguments: Arguments, prepared: inout Double) async throws -> Heard {
    let start = ContinuousClock.now
    let version = parakeetVersion(arguments.model)
    let folder = arguments.models?.appendingPathComponent("parakeet-\(arguments.model ?? "v2")", isDirectory: true)
    let models = try await AsrModels.downloadAndLoad(to: folder, version: version)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)

    var session: VocabularyBoostingSession?
    if !arguments.terms.isEmpty {
        let terms = arguments.terms.map {
            CustomVocabularyTerm(text: $0.term, aliases: $0.variants.isEmpty ? nil : $0.variants)
        }
        // The session only reads the tokenizer from the default location, so run with
        // CFFIXED_USER_HOME set to keep this out of the real Application Support folder.
        let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        session = try await VocabularyBoostingSession(
            vocabulary: CustomVocabularyContext(terms: terms),
            ctcModels: ctc,
            thresholds: .init(
                cbw: ProcessInfo.processInfo.environment["SPIKE_CBW"].flatMap(Float.init),
                minSimilarity: ProcessInfo.processInfo.environment["SPIKE_MINSIM"].flatMap(Float.init),
            ),
        )
    }
    prepared = seconds(since: start)

    var state = await TdtDecoderState.make(decoderLayers: manager.decoderLayerCount)
    let result = try await manager.transcribe(arguments.audio, decoderState: &state)
    let words = buildWordTimings(from: result.tokenTimings ?? []).map {
        Word(text: $0.word, start: $0.startTime, end: $0.endTime)
    }
    var heard = Heard(text: result.text, words: words)

    if let session {
        let samples = try AudioConverter().resampleAudioFile(arguments.audio)
        let output = await session.rescore(
            text: result.text,
            tokenTimings: result.tokenTimings ?? [],
            audioSamples: samples,
        )
        if let output {
            heard.text = output.text
            heard.notes.append("replacements: \(output.replacements.count)")
            heard.notes.append("detected: \(output.detectedTerms.count)")
        }
    }
    return heard
}

// MARK: - Main

let arguments = try Arguments()
let audioFile = try AVAudioFile(forReading: arguments.audio)
let audioSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate

var prepareSeconds = 0.0
let started = ContinuousClock.now
let heard: Heard
var modelName = arguments.model ?? ""
switch arguments.engine {
case "apple":
    heard = try await runApple(arguments, prepared: &prepareSeconds)
    modelName = arguments.model == "dictation" ? "DictationTranscriber en_US" : "SpeechTranscriber en_US"
case "whisper":
    heard = try await runWhisper(arguments, prepared: &prepareSeconds)
    modelName = arguments.model ?? "large-v3-v20240930_turbo"
case "parakeet":
    heard = try await runParakeet(arguments, prepared: &prepareSeconds)
    modelName = "parakeet-tdt-0.6b-\(arguments.model ?? "v2")"
default:
    throw SpikeError.unknownEngine(arguments.engine)
}

let output = Output(
    engine: arguments.engine,
    model: modelName,
    biased: !arguments.terms.isEmpty,
    audioSeconds: audioSeconds,
    prepareSeconds: prepareSeconds,
    transcribeSeconds: seconds(since: started) - prepareSeconds,
    peakFootprintMB: peakFootprintMB(),
    text: heard.text,
    words: heard.words,
    notes: heard.notes,
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(output).write(to: arguments.out)
print(
    "\(output.engine) \(output.model): prepare \(String(format: "%.1f", output.prepareSeconds)) s, "
        + "transcribe \(String(format: "%.1f", output.transcribeSeconds)) s "
        + "(\(String(format: "%.1f", output.audioSeconds / max(output.transcribeSeconds, 0.001)))x), "
        + "peak \(Int(output.peakFootprintMB)) MB, \(output.words.count) words",
)
