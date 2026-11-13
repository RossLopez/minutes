// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesLLM
import Synchronization
import Testing

/// What one fake server answers. Tests run in parallel, so each gets its own host.
struct StubEndpoint {
    var status = 200
    var headers = ["Content-Type": "text/event-stream"]
    /// Sent as separate pieces, as a real connection delivers them.
    var pieces: [Data] = []
    /// Fails after the pieces instead of finishing.
    var failure: URLError?
    /// Sends the pieces, then never finishes, until the request is cancelled.
    var stalls = false
    var redirect: URL?
    /// Answers like OpenAI's API does to a parameter it doesn't know.
    var rejectsReasoningEffort = false
    /// JSON answers by path, for servers asked several things. Other paths get a 404.
    var routes: [String: (status: Int, json: String)] = [:]
    var requests: [URLRequest] = []
    var bodies: [Data] = []
    var stopped = 0
}

private let endpoints = Mutex<[String: StubEndpoint]>([:])

final class StubEndpointProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let body = request.httpBodyStream.map(Self.read) ?? request.httpBody ?? Data()
        guard let stub = endpoints.withLock({ servers -> StubEndpoint? in
            servers[host]?.requests.append(request)
            servers[host]?.bodies.append(body)
            return servers[host]
        }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if let redirect = stub.redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if stub.rejectsReasoningEffort, String(bytes: body, encoding: .utf8)?.contains("reasoning_effort") == true {
            respond(
                status: 400,
                json: #"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort"}}"#,
            )
            return
        }
        if !stub.routes.isEmpty {
            let route = stub.routes[request.url?.path ?? ""]
                ?? (404, #"{"error":{"message":"File Not Found","type":"not_found_error","code":404}}"#)
            respond(status: route.status, json: route.json)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for piece in stub.pieces {
            client?.urlProtocol(self, didLoad: piece)
        }
        if stub.stalls {
            return
        }
        if let failure = stub.failure {
            // Failing at once can discard data URLSession hasn't delivered yet.
            Thread.sleep(forTimeInterval: 0.05)
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func respond(status: Int, json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        let host = request.url?.host() ?? ""
        endpoints.withLock { $0[host]?.stopped += 1 }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer {
            stream.close()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A server of its own, at `http://<host>/v1`.
func stubEndpoint(_ stub: StubEndpoint) -> URL {
    let host = "endpoint-\(UUID().uuidString.lowercased()).test"
    endpoints.withLock { $0[host] = stub }
    return URL(string: "http://\(host)/v1")!
}

func stubbed(_ base: URL) -> StubEndpoint {
    endpoints.withLock { $0[base.host()!]! }
}

@Sendable
func stubConfiguration() -> URLSessionConfiguration {
    let configuration = EndpointRequest.configuration()
    configuration.protocolClasses = [StubEndpointProtocol.self]
    return configuration
}

func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 200 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}
