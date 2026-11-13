// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLlama
import MinutesLLM
import MinutesStorage

// Runs a GGUF model the way Minutes does and reports speed and memory. A developer tool, not part
// of the app. It never downloads: point it at a model file that's already on the Mac.
//
//   minutes-llmcheck <model.gguf> --template
//   minutes-llmcheck <model.gguf> --prompt <text> [--system <text>] [--context <tokens>]
//   minutes-llmcheck <model.gguf> --summarize <meeting folder>... [--context <tokens>]
//   minutes-llmcheck --endpoint <base URL> [--model <name>] (--prompt <text> | --summarize <folder>...)
//
// --endpoint runs the same prompts on an OpenAI-compatible server, such as llama-server, for
// comparing with the built-in runtime. Its key, if it needs one, is read from MINUTES_ENDPOINT_KEY.
// The context length is --context, else what the server says, else 8192.
//
// --summarize joins the folders' transcripts end to end, with their speaker names, and summarizes
// them as one meeting with the default template.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// The peak footprint, as Activity Monitor counts it. The model file is mapped, and its clean pages
/// count only once Metal has copied them in.
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

func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
}

func option(_ name: String, in arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: name) else {
        return nil
    }
    guard index + 1 < arguments.count else {
        fail("\(name) needs a value")
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index ... index + 1)
    return value
}

var arguments = Array(CommandLine.arguments.dropFirst())
let contextOption = option("--context", in: &arguments).flatMap(Int.init)
let endpoint = option("--endpoint", in: &arguments).map { text in
    guard let url = URL(string: text) else {
        fail("--endpoint needs a URL")
    }
    return url
}

let endpointModel = option("--model", in: &arguments)
let prompt = option("--prompt", in: &arguments)
let system = option("--system", in: &arguments)
let showTemplate = arguments.contains("--template")
arguments.removeAll { $0 == "--template" }
var folders: [URL] = []
if let index = arguments.firstIndex(of: "--summarize") {
    folders = arguments[(index + 1)...].map { URL(fileURLWithPath: $0) }
    arguments.removeSubrange(index...)
}

guard arguments.count == (endpoint == nil ? 1 : 0), endpoint == nil || !showTemplate else {
    fail("usage: minutes-llmcheck (<model.gguf> | --endpoint <url> [--model <name>]) "
        + "(--template | --prompt <text> [--system <text>] | --summarize <folder>...) [--context <tokens>]")
}

/// The endpoint's model, with the context length it reports.
func endpointProvider(_ base: URL) async throws -> OpenAICompatibleProvider {
    let key = ProcessInfo.processInfo.environment["MINUTES_ENDPOINT_KEY"]
    let connection = try await EndpointClient(baseURL: base, apiKey: key, serverName: "The endpoint").connect()
    guard let model = endpointModel ?? connection.models.first else {
        fail("The endpoint has no models.")
    }
    return OpenAICompatibleProvider(
        id: "check",
        baseURL: connection.baseURL,
        model: model,
        apiKey: key,
        contextLength: contextOption ?? connection.contextLengths[model] ?? Endpoint.defaultContextLength,
        serverName: "The endpoint",
    )
}

let provider: any LLMProvider = if let endpoint {
    try await { () async throws -> OpenAICompatibleProvider in
        do {
            return try await endpointProvider(endpoint)
        } catch let error as EndpointError {
            fail(error.message)
        }
    }()
} else {
    LlamaProvider(id: "check", modelURL: URL(fileURLWithPath: arguments[0]), contextLength: contextOption ?? 32768)
}

let builtIn = provider as? LlamaProvider
var messages: [LLMMessage] = []
if let system {
    messages.append(LLMMessage(.system, system))
}

messages.append(LLMMessage(.user, prompt ?? "Say hello."))

/// The folders' lines end to end, each meeting starting where the last one's audio ended.
func joinedLines(_ folders: [URL]) throws -> (lines: [SummaryLine], title: String) {
    var lines: [SummaryLine] = []
    var offset = 0.0
    var titles: [String] = []
    for url in folders {
        let folder = MeetingFolder(url: url)
        let metadata = try folder.loadMetadata()
        let transcript = try folder.loadTranscript()
        titles.append(metadata.title)
        lines += transcript.segments.map {
            SummaryLine(start: $0.start + offset, speaker: metadata.displayName(forSpeaker: $0.speaker), text: $0.text)
        }
        offset += metadata.durationSeconds ?? (transcript.segments.last?.end ?? 0)
    }
    return (lines, titles.joined(separator: " + "))
}

if !folders.isEmpty {
    let (lines, title) = try joinedLines(folders)
    let start = ContinuousClock.now
    let summarizer = Summarizer(provider: provider)
    let summary = try await summarizer.summarize(
        lines,
        about: title,
        instructions: SummaryPrompts.defaultInstructions,
        stage: { stage in
            let elapsed = start.duration(to: .now).components.seconds
            FileHandle.standardError.write(Data("[\(elapsed) s] \(stage)\n".utf8))
        },
    )
    print(summary)
    print("---")
    let total = Int(seconds(since: start))
    if let builtIn {
        try await print(String(
            format: "%d lines, total %d s, context %d, load %.1f s, peak memory %.0f MB",
            lines.count, total, builtIn.contextLength(), builtIn.statistics.loadSeconds, peakMemoryMB(),
        ))
        await builtIn.unload()
    } else {
        // The server's own log has its speed and memory.
        try await print("\(lines.count) lines, total \(total) s, context \(provider.contextLength())")
    }
    exit(0)
}

if showTemplate, let builtIn {
    try await print(builtIn.formattedPrompt(messages))
    await builtIn.unload()
    exit(0)
}

let start = ContinuousClock.now
var answer = ""
var firstPiece: Double?
for try await piece in provider.generate(messages, options: GenerationOptions()) {
    firstPiece = firstPiece ?? seconds(since: start)
    answer += piece
    FileHandle.standardOutput.write(Data(piece.utf8))
}

guard let builtIn else {
    print(String(format: "\n---\nfirst text after %.2f s, total %.1f s", firstPiece ?? 0, seconds(since: start)))
    exit(0)
}

let stats = await builtIn.statistics
print("\n---")
try await print(String(
    format: "context %d, load %.1f s, prompt %d tokens in %.2f s (%.0f/s), answer %d tokens in %.2f s (%.1f/s)",
    builtIn.contextLength(),
    stats.loadSeconds,
    stats.promptTokens,
    stats.promptSeconds,
    Double(stats.promptTokens) / max(stats.promptSeconds, 0.001),
    stats.generatedTokens,
    stats.generateSeconds,
    Double(stats.generatedTokens) / max(stats.generateSeconds, 0.001),
))
print(String(format: "total %.1f s, peak memory %.0f MB", seconds(since: start), peakMemoryMB()))
// ggml asserts at exit if Metal still holds the model.
await builtIn.unload()
