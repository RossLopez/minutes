// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
@testable import MinutesLLM
import Synchronization
import Testing

// MARK: - A stand-in for Hugging Face

/// One fake repository. Tests run in parallel, so each uses its own repository name.
private struct StubRepository {
    var commit: String
    var body: Data
    /// What the API claims the checksum is. Defaults to the body's own.
    var claimedSHA: String?
    /// Stop after this many bytes of a response, with a lost connection.
    var dropAfter: Int?
    /// Send this many bytes, then never finish, until the request is cancelled.
    var stallAfter: Int?
    var ignoresRange = false
    var requests: [URLRequest] = []
}

private let repositories = Mutex<[String: StubRepository]>([:])

private final class StubProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url!.path
        let name = repositories.withLock { stubs in
            stubs.keys.first { path.contains("/\($0)/") || path.hasSuffix("/\($0)") }
        }
        guard let name else {
            respond(status: 404, headers: [:], body: Data())
            return
        }
        let stub = repositories.withLock { stubs in
            stubs[name]!.requests.append(request)
            return stubs[name]!
        }
        if path.hasPrefix("/api/models/") {
            serveInfo(stub)
        } else if path.contains("/resolve/\(stub.commit)/") {
            serveFile(stub)
        } else {
            respond(status: 404, headers: [:], body: Data())
        }
    }

    private func serveInfo(_ stub: StubRepository) {
        let sha = stub.claimedSHA ?? SHA256.hash(data: stub.body).map { String(format: "%02x", $0) }.joined()
        let json: [String: Any] = [
            "sha": stub.commit,
            "siblings": [
                ["rfilename": "README.md", "size": 10],
                ["rfilename": "model.gguf", "size": stub.body.count, "lfs": ["sha256": sha, "size": stub.body.count]],
            ],
        ]
        respond(status: 200, headers: [:], body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    private func serveFile(_ stub: StubRepository) {
        var start = 0
        if !stub.ignoresRange, let range = request.value(forHTTPHeaderField: "Range") {
            start = Int(range.dropFirst("bytes=".count).dropLast())!
        }
        let rest = stub.body[start...]
        if stub.ignoresRange {
            sendHead(status: 200, headers: [:])
        } else {
            sendHead(
                status: 206,
                headers: ["Content-Range": "bytes \(start)-\(stub.body.count - 1)/\(stub.body.count)"],
            )
        }
        if let stall = stub.stallAfter {
            client?.urlProtocol(self, didLoad: Data(rest.prefix(stall)))
            return
        }
        if let drop = stub.dropAfter {
            client?.urlProtocol(self, didLoad: Data(rest.prefix(drop)))
            // Failing at once can discard data URLSession hasn't delivered yet.
            Thread.sleep(forTimeInterval: 0.05)
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        // Several pieces, as a real connection delivers them.
        var offset = rest.startIndex
        while offset < rest.endIndex {
            let end = min(offset + 1000, rest.endIndex)
            client?.urlProtocol(self, didLoad: Data(rest[offset ..< end]))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func sendHead(status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func respond(status: Int, headers: [String: String], body: Data) {
        sendHead(status: status, headers: headers)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Helpers

private func body(_ count: Int = 5000) -> Data {
    Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
}

private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A model in its own fake repository, and a downloader pointed at the stub.
private func setUp(
    _ stub: StubRepository,
    space: Int64? = nil,
) throws -> (CatalogModel, ModelDownloader) {
    let name = "repo-\(UUID().uuidString)"
    repositories.withLock { $0[name] = stub }
    let model = CatalogModel(id: name, name: "Test", repository: "test/\(name)", file: "model.gguf",
                             approximateBytes: Int64(stub.body.count), recommendedMemoryGB: 8)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Models-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let downloader = ModelDownloader(
        modelsFolder: folder,
        host: URL(string: "https://stub.invalid")!,
        configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return configuration
        },
        availableSpace: { _ in space },
    )
    return (model, downloader)
}

private func update(_ model: CatalogModel, _ change: (inout StubRepository) -> Void) {
    repositories.withLock { change(&$0[model.folderName]!) }
}

private func requests(_ model: CatalogModel) -> [URLRequest] {
    repositories.withLock { $0[model.folderName]!.requests }
}

// MARK: - Tests

@Test func `the remote file has the exact size, checksum and commit`() async throws {
    let data = body()
    let (model, downloader) = try setUp(StubRepository(commit: "abc123", body: data))
    let remote = try await downloader.remoteFile(for: model)
    #expect(remote == RemoteModelFile(commit: "abc123", size: Int64(data.count), sha256: sha(data)))
    #expect(requests(model).first?.url?.query == "blobs=true")
}

@Test func `a download is checked and installed in its repository folder`() async throws {
    let data = body()
    let (model, downloader) = try setUp(StubRepository(commit: "abc123", body: data))
    let seen = Mutex<[DownloadProgress]>([])
    let url = try await downloader.download(model) { progress in seen.withLock { $0.append(progress) } }
    #expect(url == downloader.modelsFolder.appendingPathComponent("\(model.folderName)/model.gguf"))
    #expect(try Data(contentsOf: url) == data)
    #expect(downloader.isInstalled(model))
    #expect(downloader.partial(for: model) == nil)
    #expect(seen.withLock { $0.last } == DownloadProgress(received: Int64(data.count), total: Int64(data.count)))
    let fetched = try #require(requests(model).last)
    #expect(try #require(fetched.url?.path.hasSuffix("/resolve/abc123/model.gguf")))
    #expect(fetched.value(forHTTPHeaderField: "Range") == "bytes=0-")
}

@Test func `a dropped connection keeps the partial file and resumes from it`() async throws {
    let data = body()
    let (model, downloader) = try setUp(StubRepository(commit: "abc123", body: data, dropAfter: 1800))
    await #expect(throws: URLError.self) {
        try await downloader.download(model)
    }
    let kept = try #require(downloader.partial(for: model)?.received)
    #expect(kept > 0 && kept <= 1800)
    #expect(!downloader.isInstalled(model))

    update(model) { $0.dropAfter = nil }
    let url = try await downloader.download(model)
    #expect(try Data(contentsOf: url) == data)
    #expect(requests(model).last?.value(forHTTPHeaderField: "Range") == "bytes=\(kept)-")
}

@Test func `cancelling pauses, keeping what arrived`() async throws {
    let data = body()
    let (model, downloader) = try setUp(StubRepository(commit: "abc123", body: data, stallAfter: 1200))
    let task = Task {
        try await downloader.download(model)
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while downloader.partial(for: model)?.received != 1200, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(downloader.partial(for: model)?.received == 1200)

    update(model) { $0.stallAfter = nil }
    #expect(try await Data(contentsOf: downloader.download(model)) == data)
}

@Test func `a resumed download stays on the commit it started with`() async throws {
    let data = body()
    let (model, downloader) = try setUp(StubRepository(commit: "old", body: data, dropAfter: 1000))
    _ = try? await downloader.download(model)
    // The repository moves on, but the old commit's file is still served.
    update(model) { $0.dropAfter = nil }
    let apiCalls = requests(model).count { $0.url!.path.hasPrefix("/api/") }
    _ = try await downloader.download(model, remote: RemoteModelFile(commit: "new", size: 1, sha256: "x"))
    #expect(try #require(requests(model).last?.url?.path.contains("/resolve/old/")))
    #expect(requests(model).count { $0.url!.path.hasPrefix("/api/") } == apiCalls)
}

@Test func `a checksum mismatch deletes the file and installs nothing`() async throws {
    let (model, downloader) = try setUp(StubRepository(commit: "abc123", body: body(), claimedSHA: sha(Data("x".utf8))))
    await #expect(throws: ModelDownloadError.checksumMismatch) {
        try await downloader.download(model)
    }
    #expect(!downloader.isInstalled(model))
    #expect(downloader.partial(for: model) == nil)
    let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: downloader.modelsFolder.appendingPathComponent(".downloading").path,
    )
    #expect(leftovers.isEmpty)
}

@Test func `too little disk space stops before downloading`() async throws {
    let (model, downloader) = try setUp(StubRepository(commit: "abc123", body: body()), space: 10)
    await #expect(throws: ModelDownloadError.notEnoughSpace(needed: 5000 + ModelDownloader.headroom, available: 10)) {
        try await downloader.download(model)
    }
    #expect(!requests(model).contains { $0.url!.path.contains("/resolve/") })
}

@Test func `a server that ignores the range starts the file over`() async throws {
    let data = body()
    let (model, downloader) = try setUp(StubRepository(commit: "abc123", body: data, dropAfter: 700))
    _ = try? await downloader.download(model)
    update(model) {
        $0.dropAfter = nil
        $0.ignoresRange = true
    }
    #expect(try await Data(contentsOf: downloader.download(model)) == data)
}

@Test func `deleting a model removes its folder and any partial download`() async throws {
    let (model, downloader) = try setUp(StubRepository(commit: "abc123", body: body()))
    let url = try await downloader.download(model)
    try downloader.delete(model)
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    #expect(!downloader.isInstalled(model))
}

@Test func `the 12B is offered first where it fits, and every entry is distinct`() {
    #expect(ModelCatalog.recommended(forMemory: 16 << 30).id == "gemma-4-12b")
    #expect(ModelCatalog.recommended(forMemory: 8 << 30).id == "gemma-4-e4b")
    #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
    #expect(Set(ModelCatalog.all.map(\.folderName)).count == ModelCatalog.all.count)
    #expect(ModelCatalog.gemma12B.folderName == "gemma-4-12B-it-qat-q4_0-gguf")
    #expect(!ModelCatalog.gemma12B.fitsMemory(8 << 30))
    #expect(ModelCatalog.gemma12B.fitsMemory(16 << 30))
}
