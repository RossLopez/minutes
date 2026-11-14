// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A snippet from the index, whose matched words sit between U+0001 and U+0002.
enum SearchSnippet {
    static func attributed(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in snippet.split(separator: "\u{1}", omittingEmptySubsequences: false).enumerated() {
            let pieces = part.split(separator: "\u{2}", maxSplits: 1, omittingEmptySubsequences: false)
            if index > 0, let matched = pieces.first {
                var bold = AttributedString(String(matched))
                bold.inlinePresentationIntent = .stronglyEmphasized
                bold.foregroundColor = .primary
                result.append(bold)
                result.append(AttributedString(pieces.dropFirst().joined()))
            } else {
                result.append(AttributedString(String(part)))
            }
        }
        return result
    }

    /// The snippet as plain text, with its markers made into Markdown bold, for a model or a list.
    static func plain(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "\u{1}", with: "").replacingOccurrences(of: "\u{2}", with: "")
    }
}
