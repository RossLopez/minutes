// SPDX-License-Identifier: GPL-3.0-or-later

/// Holds back a character a model split across two tokens, so only whole characters are shown.
public struct UTF8Assembler: Sendable {
    public init() {}

    private var bytes: [UInt8] = []

    public mutating func append(_ more: [UInt8]) -> String? {
        bytes += more
        let complete = Self.completeLength(bytes)
        guard complete > 0 else {
            return nil
        }
        // Lenient on purpose: a stray byte becomes U+FFFD instead of losing the text.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: bytes[..<complete], as: UTF8.self)
        bytes.removeFirst(complete)
        return text
    }

    public mutating func flush() -> String? {
        defer {
            bytes = []
        }
        // Lenient on purpose: a stray byte becomes U+FFFD instead of losing the text.
        // swiftlint:disable:next optional_data_string_conversion
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    /// The length of `bytes` without a character that's still missing its last bytes.
    public static func completeLength(_ bytes: [UInt8]) -> Int {
        var index = bytes.count - 1
        var continuation = 0
        while index >= 0, continuation < 3, bytes[index] & 0xC0 == 0x80 {
            continuation += 1
            index -= 1
        }
        guard index >= 0 else {
            return bytes.count
        }
        let lead = bytes[index]
        let needed = switch lead {
        case 0xF0...: 3
        case 0xE0...: 2
        case 0xC0...: 1
        default: 0
        }
        return continuation < needed ? index : bytes.count
    }
}
