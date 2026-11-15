// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Finds the `[2]` and `[1, 3]` markers in an answer. A number with no source behind it, which a
/// model can invent, is dropped rather than shown as a link to nothing.
public enum Citations {
    /// A piece of an answer: plain text, or a citation of one source.
    public enum Piece: Equatable, Sendable {
        case text(String)
        case source(Int)
    }

    /// `[1]`, `[1, 3]`, `[1][2]` or `[1,2,3]`. Not `[x]` or Markdown links' `[text]`.
    private static var marker: Regex<(Substring, Substring)> {
        /\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\]/
    }

    /// The answer split into text and citations, for showing them as links.
    public static func pieces(of answer: String, count: Int) -> [Piece] {
        var pieces: [Piece] = []
        var rest = answer[...]
        while let match = rest.firstMatch(of: marker) {
            append(.text(String(rest[..<match.range.lowerBound])), to: &pieces)
            let numbers = numbers(in: match.output.1).filter { (1 ... count).contains($0) }
            if numbers.isEmpty {
                // An invented citation goes, and so does the space before it.
                trimTrailingSpace(&pieces)
            }
            pieces += numbers.map(Piece.source)
            rest = rest[match.range.upperBound...]
        }
        append(.text(String(rest)), to: &pieces)
        return pieces
    }

    /// The numbers cited, each once, in the order they first come.
    public static func cited(in answer: String, count: Int) -> [Int] {
        var seen: [Int] = []
        for case let .source(number) in pieces(of: answer, count: count) where !seen.contains(number) {
            seen.append(number)
        }
        return seen
    }

    /// The answer as shown: invented citations dropped, and each run of citations written once,
    /// like `[1, 3]`.
    public static func cleaned(_ answer: String, count: Int) -> String {
        var text = ""
        var run: [Int] = []
        func closeRun() {
            if !run.isEmpty {
                text += "[" + run.map(String.init).joined(separator: ", ") + "]"
                run = []
            }
        }
        for piece in pieces(of: answer, count: count) {
            switch piece {
            case let .text(part):
                closeRun()
                text += part
            case let .source(number):
                run.append(number)
            }
        }
        closeRun()
        return text
    }

    /// The answer without its citations, for showing a model its own earlier answers, whose
    /// numbers pointed at sources it no longer has.
    public static func removing(from answer: String) -> String {
        answer.replacing(/\ ?\[\d{1,3}(?:\s*,\s*\d{1,3})*\]/, with: "")
    }

    private static func numbers(in list: Substring) -> [Int] {
        list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func append(_ piece: Piece, to pieces: inout [Piece]) {
        guard case let .text(text) = piece, !text.isEmpty else {
            return
        }
        if case let .text(previous) = pieces.last {
            pieces[pieces.count - 1] = .text(previous + text)
        } else {
            pieces.append(piece)
        }
    }

    private static func trimTrailingSpace(_ pieces: inout [Piece]) {
        if case let .text(previous) = pieces.last {
            let trimmed = String(previous.reversed().drop { $0 == " " }.reversed())
            if trimmed.isEmpty {
                pieces.removeLast()
            } else {
                pieces[pieces.count - 1] = .text(trimmed)
            }
        }
    }
}
