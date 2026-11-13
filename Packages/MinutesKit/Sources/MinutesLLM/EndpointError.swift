// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a server is, as far as Minutes can tell from its addresses.
public enum NetworkLocation: String, Codable, Comparable, Sendable {
    /// Loopback: `localhost`, `127.0.0.0/8` and `::1`.
    case thisMac
    /// Private and link-local ranges, including Tailscale's.
    case localNetwork
    /// Anything else. Transcripts sent here leave the user's network.
    case internet

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .thisMac: 0
        case .localNetwork: 1
        case .internet: 2
        }
    }
}

/// Why a request to an OpenAI-compatible server failed, written for the user. Never holds what
/// the server said, which can echo the prompt back.
public struct EndpointError: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Refused, no such host, or no route.
        case cannotConnect
        /// Five minutes without a byte.
        case timedOut
        case secureConnectionFailed
        /// Plain http to a name macOS doesn't count as local, like `studio.lan`. App Transport
        /// Security only allows it to IP addresses, `.local` names and names without a dot.
        case insecureName
        case keyRejected
        case modelNotFound(String)
        /// A 404 that isn't about the model: usually a base URL without its `/v1`.
        case wrongAddress
        /// The server's own context is smaller than what Minutes sent.
        case contextExceeded
        /// A redirect, which Minutes doesn't follow so the transcript and key stay put.
        case redirected
        /// HTML, or JSON that isn't a chat completion.
        case notCompatible
        case rejected(status: Int)
        /// A 400 about `reasoning_effort`, from a server that doesn't take it. The provider tries
        /// again without it, so the user doesn't see this.
        case rejectedReasoningOption(status: Int)
        case serverProblem(status: Int)
    }

    public var reason: Reason
    /// The endpoint's name, as the user gave it.
    public var server: String
    public var location: NetworkLocation

    public init(_ reason: Reason, server: String, location: NetworkLocation = .thisMac) {
        self.reason = reason
        self.server = server
        self.location = location
    }

    public var message: String {
        switch reason {
        case .cannotConnect: cannotConnectMessage
        case .timedOut: "\(server) stopped responding."
        case .secureConnectionFailed: "Minutes couldn't make a secure connection to \(server)."
        case .insecureName:
            "macOS only allows http:// to an IP address or a .local name. Use the server's IP address, or https://."
        case .keyRejected: "\(server) didn't accept the API key."
        case let .modelNotFound(model): "\(model) isn't on \(server) anymore. Pick another model in Settings."
        case .wrongAddress:
            "\(server) has no OpenAI-compatible API at this address. The base URL usually ends in /v1."
        case .contextExceeded:
            "The transcript is longer than \(server) accepts. In Settings, set its context length to the server's."
        case .redirected: "\(server) redirected to another address. Enter that address instead."
        case .notCompatible: "\(server) doesn't look like an OpenAI-compatible server."
        case let .rejected(status), let .rejectedReasoningOption(status):
            "\(server) refused the request (status \(status))."
        case let .serverProblem(status): "\(server) had a problem (status \(status))."
        }
    }

    private var cannotConnectMessage: String {
        switch location {
        case .thisMac:
            "Couldn't reach \(server). Check that the server is running."
        case .localNetwork:
            "Couldn't reach \(server). Check that it's running, and that Minutes is allowed in System Settings › "
                + "Privacy & Security › Local Network."
        case .internet:
            "Couldn't reach \(server). Check your internet connection and the server's address."
        }
    }

    /// Reads a failed response: its status and, without keeping it, the body's wording.
    static func reason(status: Int, body: Data, model: String) -> Reason {
        let text = errorText(body).lowercased()
        let aboutModel = text.contains("model")
            && ["not found", "not_found", "does not exist", "no such", "not loaded", "unknown"]
            .contains { text.contains($0) }
        let aboutLength = [400, 413, 422].contains(status)
            && ["context", "too long", "exceed", "too many tokens"].contains { text.contains($0) }
        switch status {
        case 401, 403:
            return .keyRejected
        case _ where aboutModel:
            return .modelNotFound(model)
        case 404:
            return .wrongAddress
        case _ where aboutLength:
            return .contextExceeded
        case _ where [400, 422].contains(status) && text.contains("reasoning"):
            return .rejectedReasoningOption(status: status)
        case 300 ..< 400:
            return .redirected
        case 500...:
            return .serverProblem(status: status)
        default:
            return .rejected(status: status)
        }
    }

    /// The parts of an error body that say what went wrong: OpenAI's `error.message`, `error.type`
    /// and `error.code`, or the whole thing when it isn't that shape.
    private static func errorText(_ body: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: body)
        guard let error = (object as? [String: Any])?["error"] else {
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: body.prefix(4096), as: UTF8.self)
        }
        if let text = error as? String {
            return text
        }
        let fields = error as? [String: Any] ?? [:]
        return ["message", "type", "code"].compactMap { fields[$0].map { "\($0)" } }.joined(separator: " ")
    }

    /// What a failed connection means, or nil for errors that aren't about the server.
    static func reason(for error: URLError) -> Reason? {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
             .notConnectedToInternet, .resourceUnavailable, .internationalRoamingOff, .dataNotAllowed:
            .cannotConnect
        case .timedOut:
            .timedOut
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            .secureConnectionFailed
        case .appTransportSecurityRequiresSecureConnection:
            .insecureName
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData,
             .zeroByteResource:
            .notCompatible
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            .redirected
        case .userAuthenticationRequired, .userCancelledAuthentication:
            .keyRejected
        default:
            nil
        }
    }
}
