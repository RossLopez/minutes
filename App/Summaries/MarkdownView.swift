// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One block of a Markdown document: a heading, paragraph, list item and so on, with its inline
/// styling kept.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        /// `ordinal` is set in numbered lists. `checked` is set for `[ ]` and `[x]` items.
        case listItem(depth: Int, ordinal: Int?, checked: Bool?)
        case code
        case quote
        case rule
    }

    let id: Int
    let kind: Kind
    let text: AttributedString

    /// Splits Markdown into blocks with Foundation's parser. Text it can't parse is one paragraph.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible,
        )
        guard let document = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }
        var blocks: [MarkdownBlock] = []
        var lastIdentity: Int?
        for (intent, range) in document.runs[\.presentationIntent] {
            let identity = intent?.components.first?.identity
            var text = AttributedString(document[range])
            if let identity, identity == lastIdentity, let last = blocks.popLast() {
                // The same block, split into runs by inline styling.
                var joined = last.text
                joined.append(text)
                text = joined
            }
            lastIdentity = identity
            blocks.append(block(id: blocks.count, intent: intent, text: text))
        }
        return blocks.map(\.withCheckbox)
    }

    private static func block(id: Int, intent: PresentationIntent?, text: AttributedString) -> MarkdownBlock {
        let kinds = intent?.components.map(\.kind) ?? []
        var kind = Kind.paragraph
        for component in kinds {
            switch component {
            case let .header(level):
                kind = .heading(level: level)
            case .codeBlock:
                kind = .code
            case .blockQuote where kind == .paragraph:
                kind = .quote
            case .thematicBreak:
                kind = .rule
            default:
                break
            }
        }
        if kind == .paragraph, let item = listItem(kinds) {
            kind = item
        }
        return MarkdownBlock(id: id, kind: kind, text: text)
    }

    /// The innermost list decides the number. Components run from the innermost out.
    private static func listItem(_ kinds: [PresentationIntent.Kind]) -> Kind? {
        var depth = 0
        var ordinal: Int?
        var isOrdered = false
        for component in kinds {
            switch component {
            case let .listItem(number) where depth == 0:
                ordinal = ordinal ?? number
            case .orderedList:
                isOrdered = isOrdered || depth == 0
                depth += 1
            case .unorderedList:
                depth += 1
            default:
                break
            }
        }
        return depth > 0 ? .listItem(depth: depth, ordinal: isOrdered ? ordinal : nil, checked: nil) : nil
    }

    /// Foundation leaves a task list's `[ ]` in the text, so it's read here.
    private var withCheckbox: MarkdownBlock {
        guard case let .listItem(depth, ordinal, _) = kind else {
            return self
        }
        let plain = String(text.characters.prefix(4))
        let checked: Bool? = switch plain.lowercased() {
        case "[ ] ": false
        case "[x] ": true
        default: nil
        }
        guard let checked else {
            return self
        }
        let rest = AttributedString(text[text.index(text.startIndex, offsetByCharacters: 4)...])
        return MarkdownBlock(id: id, kind: .listItem(depth: depth, ordinal: ordinal, checked: checked), text: rest)
    }
}

/// Renders Markdown as native, selectable text.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = MarkdownBlock.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case let .heading(level):
            Text(block.text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, block.id == 0 ? 0 : 8)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            Text(block.text)
        case let .listItem(depth, ordinal, checked):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                marker(ordinal: ordinal, checked: checked)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(block.text)
            }
            .padding(.leading, CGFloat(depth - 1) * 18)
            .accessibilityElement(children: .combine)
        case .code:
            Text(block.text)
                .font(.body.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 6))
        case .quote:
            Text(block.text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 3)
                }
        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func marker(ordinal: Int?, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square" : "square")
                .foregroundStyle(.secondary)
                .accessibilityLabel(checked ? "Done" : "To do")
        } else if let ordinal {
            Text("\(ordinal).")
                .monospacedDigit()
        } else {
            Text("•")
                .accessibilityHidden(true)
        }
    }
}
