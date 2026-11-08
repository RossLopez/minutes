// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

/// Corrects what an engine heard, using the user's list. It's the same on every engine, and on
/// Apple's it's the only way the list has any effect.
///
/// Matches whole words, ignoring case and the punctuation around them, longest match first. Words
/// that combine into one term keep the first's start and the last's end. A term also fixes its own
/// capitalization, so "bpa" becomes "BPA" without being listed as a variant.
public struct VocabularyReplacer: Sendable {
    private let termByPhrase: [String: String]
    private let longestPhrase: Int

    public init(entries: [VocabularyEntry]) {
        var terms: [String: String] = [:]
        var longest = 0
        // Terms go first, so one entry's variant can't take over another entry's term.
        for (phrase, term) in entries.map({ ($0.term, $0.term) }) + entries.flatMap({ entry in
            entry.variants.map { ($0, entry.term) }
        }) {
            let words = phrase.split(whereSeparator: \.isWhitespace).map { WordParts(String($0)).core }
            guard !words.isEmpty, words.allSatisfy({ !$0.isEmpty }) else {
                continue
            }
            let key = words.joined(separator: " ")
            if terms[key] == nil {
                terms[key] = term
                longest = max(longest, words.count)
            }
        }
        termByPhrase = terms
        longestPhrase = longest
    }

    public func apply(to words: [TranscriptWord]) -> [TranscriptWord] {
        guard !termByPhrase.isEmpty else {
            return words
        }
        let parts = words.map { WordParts($0.text) }
        var result: [TranscriptWord] = []
        result.reserveCapacity(words.count)
        var index = 0
        while index < words.count {
            if let match = match(at: index, in: parts) {
                let last = index + match.count - 1
                result.append(TranscriptWord(
                    text: parts[index].leading + match.term + parts[last].ending(after: match.term),
                    start: words[index].start,
                    end: words[last].end,
                ))
                index += match.count
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result
    }

    private func match(at index: Int, in parts: [WordParts]) -> (term: String, count: Int)? {
        for count in stride(from: min(longestPhrase, parts.count - index), through: 1, by: -1) {
            let range = index ..< index + count
            // Punctuation inside a span means the words were in separate phrases.
            let isContinuous = range.dropFirst().allSatisfy { parts[$0].leading.isEmpty }
                && range.dropLast().allSatisfy { parts[$0].trailing.isEmpty }
            guard isContinuous else {
                continue
            }
            let key = range.map { parts[$0].core }.joined(separator: " ")
            if let term = termByPhrase[key] {
                return (term, count)
            }
        }
        return nil
    }
}

/// A word split into its surrounding punctuation and its lowercased core.
private struct WordParts {
    private static let openers = CharacterSet(charactersIn: "\"'“‘([{«")
    private static let closers = CharacterSet(charactersIn: "\"'”’)]}».,;:!?…")

    let leading: String
    let core: String
    /// Everything after the core, including a possessive ending.
    let trailing: String

    init(_ text: String) {
        var body = Substring(text)
        var opening = ""
        while let first = body.first, first.unicodeScalars.allSatisfy(Self.openers.contains) {
            opening.append(body.removeFirst())
        }
        var closing = ""
        while let last = body.last, last.unicodeScalars.allSatisfy(Self.closers.contains) {
            closing.insert(body.removeLast(), at: closing.startIndex)
        }
        for ending in ["'s", "’s", "'S", "’S"] where body.hasSuffix(ending) {
            body.removeLast(ending.count)
            closing = ending + closing
            break
        }
        leading = opening
        core = body.lowercased()
        trailing = closing
    }

    /// What follows a replacement. A term ending in a period doesn't get a second one.
    func ending(after term: String) -> String {
        trailing.first.map { term.hasSuffix(String($0)) } == true ? String(trailing.dropFirst()) : trailing
    }
}
