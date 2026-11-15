// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Turns what someone typed into an FTS5 query. Every word is quoted, so FTS5's own syntax, like
/// `NEAR`, `*`, `-` or a stray quote, is only ever read as text.
public enum FTSQuery {
    /// Every word must match, and the last one may be unfinished. For the search field, where
    /// results come as you type.
    public static func allWords(_ text: String) -> String? {
        let terms = typedTerms(text)
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    /// Each word as a query of its own, the last one as a prefix while it's still being typed.
    static func typedTerms(_ text: String) -> [String] {
        var terms = words(in: text).map(quote)
        // Only the last word can still be being typed.
        if text.last.map({ $0.isLetter || $0.isNumber }) == true, !terms.isEmpty {
            terms[terms.count - 1] += " *"
        }
        return terms
    }

    /// Any word may match, leaving out common words, and bm25 ranks passages that match more of
    /// them first. For questions.
    public static func anyWord(_ text: String) -> String? {
        let words = words(in: text).filter { !stopWords.contains($0.lowercased()) }
        guard !words.isEmpty else {
            return nil
        }
        return Array(Set(words.map { $0.lowercased() })).sorted().map(quote).joined(separator: " OR ")
    }

    static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    private static func quote(_ word: String) -> String {
        "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Words too common to say anything about which passage answers a question.
    static let stopWords: Set<String> = [
        "a", "about", "after", "all", "also", "an", "and", "any", "are", "as", "at", "be", "been", "before", "but",
        "by", "can", "could", "did", "do", "does", "for", "from", "had", "has", "have", "he", "her", "him", "his",
        "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "of", "on", "or", "our", "she", "so", "than",
        "that", "the", "their", "them", "then", "there", "these", "they", "this", "to", "us", "was", "we", "were",
        "what", "when", "where", "which", "who", "whom", "why", "will", "with", "would", "you", "your",
    ]
}
