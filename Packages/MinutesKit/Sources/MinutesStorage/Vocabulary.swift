// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A term to get right, and what speech recognition tends to hear instead.
public struct VocabularyEntry: Codable, Equatable, Sendable {
    public var term: String
    public var variants: [String]

    public init(term: String, variants: [String] = []) {
        self.term = term
        self.variants = variants
    }
}

/// Reads and writes `Vocabulary.txt`, with lines like `Tanium = tan ium, tannium`, and CSV files.
public enum Vocabulary {
    private static let header = """
    # Custom vocabulary for Minutes. One term per line, with what it's often heard as after an equals sign:
    #   Tanium = tan ium, tannium
    # Editing the list in Settings rewrites this file, which replaces these comments.
    """

    public static func parse(_ text: String) -> [VocabularyEntry] {
        let entries = text.split(whereSeparator: \.isNewline).compactMap { line -> VocabularyEntry? in
            let trimmed = line.trimmingCharacters(in: Self.ignoredAtEdges)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                return nil
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let variants = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
            return VocabularyEntry(term: String(parts[0]), variants: variants)
        }
        return normalized(entries)
    }

    public static func render(_ entries: [VocabularyEntry]) -> String {
        let lines = normalized(entries).map { entry in
            entry.variants.isEmpty ? entry.term : "\(entry.term) = \(entry.variants.joined(separator: ", "))"
        }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    /// The first column is the term, and every other cell is a variant. A cell can hold several, split by commas.
    public static func parseCSV(_ text: String) -> [VocabularyEntry] {
        var rows = csvRows(text)
        if rows.first?.first?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("term") == .orderedSame {
            rows.removeFirst()
        }
        return normalized(rows.compactMap { row in
            guard let term = row.first else {
                return nil
            }
            return VocabularyEntry(
                term: term,
                variants: row.dropFirst().flatMap { $0.split(separator: ",").map(String.init) },
            )
        })
    }

    public static func renderCSV(_ entries: [VocabularyEntry]) -> String {
        let rows = normalized(entries).map { entry in
            ([entry.term] + entry.variants).map(csvCell).joined(separator: ",")
        }
        return (["term,variants"] + rows).joined(separator: "\n") + "\n"
    }

    /// Adds what's imported to what's there. A term already on the list keeps its spelling and gains any new variants.
    public static func merging(_ existing: [VocabularyEntry], with imported: [VocabularyEntry]) -> [VocabularyEntry] {
        normalized(existing + imported)
    }

    /// Trims everything, drops empty terms and repeats, and combines entries for the same term.
    public static func normalized(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var result: [VocabularyEntry] = []
        var indexByTerm: [String: Int] = [:]
        for entry in entries {
            let term = collapsed(entry.term)
            guard !term.isEmpty else {
                continue
            }
            let index = indexByTerm[term.lowercased()] ?? result.count
            if index == result.count {
                indexByTerm[term.lowercased()] = index
                result.append(VocabularyEntry(term: term))
            }
            for variant in entry.variants.map(collapsed) where !variant.isEmpty {
                let isNew = !result[index].variants.contains { $0.caseInsensitiveCompare(variant) == .orderedSame }
                if isNew, variant.caseInsensitiveCompare(term) != .orderedSame {
                    result[index].variants.append(variant)
                }
            }
        }
        return result
    }

    /// A byte order mark isn't whitespace to Foundation, and spreadsheets and Windows editors add one.
    private static let ignoredAtEdges = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}"))

    private static func collapsed(_ text: String) -> String {
        text.trimmingCharacters(in: ignoredAtEdges).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func csvCell(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else {
            return text
        }
        return "\"\(text.replacing("\"", with: "\"\""))\""
    }

    /// RFC 4180: quoted cells can hold commas, line breaks and doubled quotes.
    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var isQuoted = false
        var characters = text.makeIterator()
        var next = characters.next()
        while let character = next {
            next = characters.next()
            if isQuoted {
                if character != "\"" {
                    cell.append(character)
                } else if next == "\"" {
                    cell.append("\"")
                    next = characters.next()
                } else {
                    isQuoted = false
                }
            } else if character == "\"", cell.isEmpty {
                isQuoted = true
            } else if character == "," {
                row.append(cell)
                cell = ""
            } else if character.isNewline {
                row.append(cell)
                rows.append(row)
                row = []
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if !cell.isEmpty || !row.isEmpty {
            row.append(cell)
            rows.append(row)
        }
        return rows
    }
}
