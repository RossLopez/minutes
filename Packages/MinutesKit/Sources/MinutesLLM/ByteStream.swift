// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A data task as a stream of its response and body pieces. Ending the stream cancels the task.
final class ByteStream: NSObject, URLSessionDataDelegate, Sendable {
    enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    enum Redirects: Sendable {
        /// Model downloads, which Hugging Face redirects to its file servers.
        case follow
        /// Endpoints, which get the user's transcript and key: a redirect elsewhere could take both
        /// with it. A refused redirect arrives as the 3xx response itself.
        case sameOrigin
    }

    private let continuation: AsyncThrowingStream<Event, any Error>.Continuation
    private let redirects: Redirects

    private init(_ continuation: AsyncThrowingStream<Event, any Error>.Continuation, redirects: Redirects) {
        self.continuation = continuation
        self.redirects = redirects
    }

    static func events(
        for request: URLRequest,
        configuration: URLSessionConfiguration,
        redirects: Redirects = .follow,
    ) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let session = URLSession(
                configuration: configuration,
                delegate: ByteStream(continuation, redirects: redirects),
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
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
    ) async -> URLRequest? {
        switch redirects {
        case .follow:
            return request
        case .sameOrigin:
            guard let original = task.originalRequest?.url, let next = request.url else {
                return nil
            }
            return Self.sameOrigin(original, next) ? request : nil
        }
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host()?.lowercased() == second.host()?.lowercased()
            && first.port == second.port
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
    ) async -> URLSession.ResponseDisposition {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: URLError(.badServerResponse))
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
