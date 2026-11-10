// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// What Hugging Face says about a model file, pinned to one commit.
public struct RemoteModelFile: Codable, Equatable, Sendable {
    public var commit: String
    public var size: Int64
    /// Lowercase hex.
    public var sha256: String

    public init(commit: String, size: Int64, sha256: String) {
        self.commit = commit
        self.size = size
        self.sha256 = sha256
    }
}

public struct DownloadProgress: Equatable, Sendable {
    public var received: Int64
    public var total: Int64

    public init(received: Int64, total: Int64) {
        self.received = received
        self.total = total
    }

    public var fraction: Double {
        total > 0 ? Double(received) / Double(total) : 0
    }
}

public enum ModelDownloadError: Error, Equatable, Sendable {
    /// The repository no longer has the file Minutes expects.
    case fileNotFound
    case notEnoughSpace(needed: Int64, available: Int64)
    /// The finished file didn't match its checksum, so it was deleted.
    case checksumMismatch
    case server(status: Int)
    /// The connection ended early or sent something unexpected. The partial file is kept.
    case incomplete
}

/// Downloads catalog models into `Models/`, resumably and checked against their SHA-256.
///
/// A download writes `Models/.downloading/<file>.partial`, with `<file>.json` beside it holding the
/// commit, size and checksum it started with. Resuming reuses those, so a file is never stitched
/// together from two versions. Only a file that matches its checksum is moved into
/// `Models/<repository name>/<file>`. Cancelling the task pauses: the partial file stays.
///
/// Nothing touches the network until `remoteFile(for:)` or `download` is called. Run one download
/// per model at a time.
public struct ModelDownloader: Sendable {
    public let modelsFolder: URL
    private let host: URL
    private let configuration: @Sendable () -> URLSessionConfiguration
    private let availableSpace: @Sendable (URL) -> Int64?

    /// Free space Minutes leaves on the disk after a download, so a model never fills it.
    public static let headroom: Int64 = 1 << 30

    public init(
        modelsFolder: URL,
        host: URL = URL(string: "https://huggingface.co")!,
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral },
        availableSpace: @escaping @Sendable (URL) -> Int64? = ModelDownloader.volumeAvailableSpace,
    ) {
        self.modelsFolder = modelsFolder
        self.host = host
        self.configuration = configuration
        self.availableSpace = availableSpace
    }

    // MARK: - On disk

    public func installedFile(for model: CatalogModel) -> URL {
        modelsFolder.appendingPathComponent(model.folderName, isDirectory: true).appendingPathComponent(model.file)
    }

    public func isInstalled(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: installedFile(for: model).path)
    }

    /// A paused download: what it's fetching and how much it has.
    public func partial(for model: CatalogModel) -> (remote: RemoteModelFile, received: Int64)? {
        guard let data = try? Data(contentsOf: sidecarFile(model)),
              let remote = try? JSONDecoder().decode(RemoteModelFile.self, from: data)
        else {
            return nil
        }
        return (remote, fileSize(partialFile(model)))
    }

    public func discardPartial(for model: CatalogModel) throws {
        for url in [partialFile(model), sidecarFile(model)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func delete(_ model: CatalogModel) throws {
        try discardPartial(for: model)
        let folder = installedFile(for: model).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Network

    /// Asks Hugging Face for the file's exact size, checksum and current commit.
    public func remoteFile(for model: CatalogModel) async throws -> RemoteModelFile {
        var components = URLComponents(
            url: host.appendingPathComponent("api/models/\(model.repository)"),
            resolvingAgainstBaseURL: false,
        )!
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        let session = URLSession(configuration: configuration())
        defer {
            session.finishTasksAndInvalidate()
        }
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ModelDownloadError.server(status: status)
        }
        let info = try JSONDecoder().decode(RepositoryInfo.self, from: data)
        guard let sibling = info.siblings.first(where: { $0.rfilename == model.file }),
              let lfs = sibling.lfs
        else {
            throw ModelDownloadError.fileNotFound
        }
        return RemoteModelFile(commit: info.sha, size: lfs.size, sha256: lfs.sha256.lowercased())
    }

    /// Throws `notEnoughSpace` unless the rest of the file fits with `headroom` to spare.
    public func checkSpace(for model: CatalogModel, remote: RemoteModelFile) throws {
        try FileManager.default.createDirectory(at: downloadingFolder, withIntermediateDirectories: true)
        let have = partial(for: model)?.remote == remote ? fileSize(partialFile(model)) : 0
        let needed = remote.size - have + Self.headroom
        if let available = availableSpace(downloadingFolder), available < needed {
            throw ModelDownloadError.notEnoughSpace(needed: needed, available: available)
        }
    }

    /// Downloads the model, or resumes its paused download. Returns the installed file.
    ///
    /// - Parameter remote: from `remoteFile(for:)`, when the caller already asked. A paused
    ///   download ignores it and keeps the version it started with.
    @discardableResult
    public func download(
        _ model: CatalogModel,
        remote given: RemoteModelFile? = nil,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in },
    ) async throws -> URL {
        let remote: RemoteModelFile
        if let paused = partial(for: model)?.remote {
            remote = paused
        } else {
            try? FileManager.default.removeItem(at: partialFile(model))
            if let given {
                remote = given
            } else {
                remote = try await remoteFile(for: model)
            }
        }
        try checkSpace(for: model, remote: remote)
        try JSONEncoder().encode(remote).write(to: sidecarFile(model), options: .atomic)
        if !FileManager.default.fileExists(atPath: partialFile(model).path) {
            FileManager.default.createFile(atPath: partialFile(model).path, contents: nil)
        }

        var writer = try PartialWriter(url: partialFile(model), total: remote.size, progress: progress)
        defer {
            writer.close()
        }
        if writer.received < remote.size {
            try await fetch(model, remote: remote, into: &writer)
        }
        guard writer.received == remote.size else {
            throw ModelDownloadError.incomplete
        }
        let digest = writer.finish()
        guard digest == remote.sha256 else {
            try? discardPartial(for: model)
            throw ModelDownloadError.checksumMismatch
        }
        let destination = installedFile(for: model)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partialFile(model), to: destination)
        try? FileManager.default.removeItem(at: sidecarFile(model))
        return destination
    }

    private func fetch(_ model: CatalogModel, remote: RemoteModelFile, into writer: inout PartialWriter) async throws {
        let url = host.appendingPathComponent("\(model.repository)/resolve/\(remote.commit)/\(model.file)")
        var request = URLRequest(url: url)
        request.setValue("bytes=\(writer.received)-", forHTTPHeaderField: "Range")
        for try await event in ByteStream.events(for: request, configuration: configuration()) {
            switch event {
            case let .response(response):
                switch response.statusCode {
                case 206:
                    guard contentRangeStart(response) == writer.received else {
                        throw ModelDownloadError.incomplete
                    }
                case 200:
                    // The server ignored the range and sent the whole file.
                    try writer.restart()
                case 416:
                    return
                default:
                    throw ModelDownloadError.server(status: response.statusCode)
                }
            case let .data(data):
                guard writer.received + Int64(data.count) <= remote.size else {
                    throw ModelDownloadError.incomplete
                }
                try writer.append(data)
            }
        }
        // A cancelled stream just ends, which would pass for a short download.
        try Task.checkCancellation()
    }

    private func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        // "bytes 100-199/200"
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let range = value.split(separator: " ").last,
              let start = range.split(separator: "-").first
        else {
            return nil
        }
        return Int64(start)
    }

    // MARK: - Files

    private var downloadingFolder: URL {
        modelsFolder.appendingPathComponent(".downloading", isDirectory: true)
    }

    private func partialFile(_ model: CatalogModel) -> URL {
        downloadingFolder.appendingPathComponent("\(model.file).partial")
    }

    private func sidecarFile(_ model: CatalogModel) -> URL {
        downloadingFolder.appendingPathComponent("\(model.file).json")
    }

    private func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }

    public static func volumeAvailableSpace(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// The parts of `/api/models/<repo>?blobs=true` Minutes reads.
private struct RepositoryInfo: Decodable {
    var sha: String
    var siblings: [RepositoryFile]
}

private struct RepositoryFile: Decodable {
    var rfilename: String
    /// Present for files stored with Git LFS, which models are.
    var lfs: LargeFile?
}

private struct LargeFile: Decodable {
    var sha256: String
    var size: Int64
}

/// Appends to the partial file and hashes everything in it, including what an earlier run wrote.
private struct PartialWriter {
    private let handle: FileHandle
    private let total: Int64
    private let progress: @Sendable (DownloadProgress) -> Void
    private var hasher = SHA256()
    private var lastReport: ContinuousClock.Instant?
    private(set) var received: Int64 = 0

    init(url: URL, total: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) throws {
        handle = try FileHandle(forUpdating: url)
        self.total = total
        self.progress = progress
        // Re-hash what's already there, so the checksum covers the whole file.
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            received += Int64(chunk.count)
        }
        report(force: true)
    }

    mutating func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        received += Int64(data.count)
        report(force: received == total)
    }

    mutating func restart() throws {
        try handle.truncate(atOffset: 0)
        hasher = SHA256()
        received = 0
    }

    func finish() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func close() {
        try? handle.close()
    }

    private mutating func report(force: Bool) {
        let now = ContinuousClock.now
        if force || lastReport.map({ $0.duration(to: now) >= .milliseconds(200) }) ?? true {
            lastReport = now
            progress(DownloadProgress(received: received, total: total))
        }
    }
}

/// A data task as a stream of its response and body pieces. Ending the stream cancels the task.
private final class ByteStream: NSObject, URLSessionDataDelegate, Sendable {
    enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    private let continuation: AsyncThrowingStream<Event, any Error>.Continuation

    private init(_ continuation: AsyncThrowingStream<Event, any Error>.Continuation) {
        self.continuation = continuation
    }

    static func events(
        for request: URLRequest,
        configuration: URLSessionConfiguration,
    ) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let session = URLSession(
                configuration: configuration,
                delegate: ByteStream(continuation),
                delegateQueue: nil,
            )
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.finishTasksAndInvalidate()
            }
            task.resume()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
    ) async -> URLSession.ResponseDisposition {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: ModelDownloadError.incomplete)
            return .cancel
        }
        continuation.yield(.response(response))
        return .allow
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: any Error?) {
        continuation.finish(throwing: error)
    }
}
