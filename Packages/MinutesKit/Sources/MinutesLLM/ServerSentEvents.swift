// SPDX-License-Identifier: GPL-3.0-or-later

/// One event from a `text/event-stream` response.
public struct ServerSentEvent: Equatable, Sendable {
    /// The `event:` field, when there is one.
    public var name: String?
    /// The `data:` lines, joined with newlines.
    public var data: String

    public init(name: String? = nil, data: String) {
        self.name = name
        self.data = data
    }
}

/// Reads server-sent events from bytes as they arrive, however the connection splits them.
/// Lines may end in LF, CRLF or CR, as the format allows.
public struct ServerSentEventParser: Sendable {
    public struct TooLarge: Error, Equatable {}

    /// Far more than any one piece of an answer, so a server can't use up memory with a line
    /// that never ends.
    public static let maximumEventBytes = 4 << 20

    private var line: [UInt8] = []
    private var afterCarriageReturn = false
    private var dataLines: [String] = []
    private var name: String?
    private var eventBytes = 0

    public init() {}

    /// The events these bytes complete, in order.
    public mutating func feed(_ bytes: some Sequence<UInt8>) throws(TooLarge) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\n") where afterCarriageReturn:
                // The second half of a CRLF.
                afterCarriageReturn = false
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                afterCarriageReturn = byte == UInt8(ascii: "\r")
                if let event = endLine() {
                    events.append(event)
                }
            default:
                afterCarriageReturn = false
                line.append(byte)
                eventBytes += 1
                guard eventBytes <= Self.maximumEventBytes else {
                    throw TooLarge()
                }
            }
        }
        return events
    }

    /// An event the stream ended in the middle of. The format says to drop it, but some servers
    /// leave off the last blank line.
    public mutating func finish() -> ServerSentEvent? {
        if !line.isEmpty {
            _ = endLine()
        }
        return dispatch()
    }

    private mutating func endLine() -> ServerSentEvent? {
        defer {
            line.removeAll(keepingCapacity: true)
        }
        guard !line.isEmpty else {
            return dispatch()
        }
        // Lines starting with a colon are comments, which servers send to keep a connection open.
        guard line.first != UInt8(ascii: ":") else {
            eventBytes -= line.count
            return nil
        }
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: line, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " {
                value = value.dropFirst()
            }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "data":
            dataLines.append(String(value))
        case "event":
            name = String(value)
        default:
            // `id` and `retry` are for reconnecting, which a chat answer never does.
            break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            dataLines = []
            name = nil
            eventBytes = 0
        }
        guard !dataLines.isEmpty else {
            return nil
        }
        return ServerSentEvent(name: name, data: dataLines.joined(separator: "\n"))
    }
}
