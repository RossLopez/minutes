// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The notes editor: plain text that continues Markdown lists, with each line's time in a quiet
/// margin. AppKit's text view, since SwiftUI's can't say where its lines are drawn.
struct NotesTextView: NSViewRepresentable {
    var text: String
    var times: [Double?]
    var bottomInset: CGFloat = 0
    /// Whether clicking a time plays the audio from there.
    var canPlay: Bool
    var onChange: (String) -> Void
    var onPlay: (Double) -> Void
    var onFocus: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        let textView = NotesNSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocus($0) }
        Self.configure(textView)
        textView.string = text
        scrollView.documentView = textView

        let ruler = TimeRuler(scrollView: scrollView, textView: textView)
        ruler.onPlay = { [weak coordinator = context.coordinator] in coordinator?.parent.onPlay($0) }
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.observeScrolling(of: scrollView)
        update(ruler, text: text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView, let ruler = context.coordinator.ruler else {
            return
        }
        // Only differs when the notes were read again from disk.
        if textView.string != text {
            textView.string = text
        }
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        update(ruler, text: text)
    }

    private func update(_ ruler: TimeRuler, text: String) {
        ruler.times = times
        ruler.lineStarts = Self.lineStarts(of: text)
        ruler.canPlay = canPlay
        ruler.toolTip = canPlay ? "Click a time to play the recording from there" : nil
        ruler.needsDisplay = true
    }

    private static func configure(_ textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 4, height: 10)
        // Markdown stays plain: no curly quotes or dashes that change what the file says.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Notes")
        textView.setAccessibilityIdentifier("notesEditor")
    }

    /// Where each line starts, in UTF-16 offsets, splitting where `NoteTimeline.lines` does.
    static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for character in text {
            offset += character.utf16.count
            if character.isNewline {
                starts.append(offset)
            }
        }
        return starts
    }

    /// `3:15`, or `1:02:04` past an hour.
    static func label(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextView
        weak var textView: NSTextView?
        weak var ruler: TimeRuler?
        private var scrollObserver: any NSObjectProtocol?

        init(parent: NotesTextView) {
            self.parent = parent
        }

        func observeScrolling(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.ruler?.needsDisplay = true
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            parent.onChange(textView.string)
            ruler?.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            selector == #selector(NSResponder.insertNewline(_:)) && MarkdownLists.continueList(in: textView)
        }

        func textView(_ view: NSTextView, menu: NSMenu, for _: NSEvent, at charIndex: Int) -> NSMenu? {
            guard parent.canPlay, let ruler, let seconds = ruler.time(atCharacter: charIndex) else {
                return menu
            }
            let item = NSMenuItem(title: "Play from \(NotesTextView.label(seconds))",
                                  action: #selector(play(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            _ = view
            return menu
        }

        @objc private func play(_ sender: NSMenuItem) {
            if let seconds = sender.representedObject as? Double {
                parent.onPlay(seconds)
            }
        }
    }
}

/// Says when it gains and loses focus, so Space and ⌘⌫ go to the text while it has it.
final class NotesNSTextView: NSTextView {
    var onFocus: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocus(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocus(false)
        }
        return resigned
    }
}

/// Return continues a Markdown list item, and an empty item ends the list.
enum MarkdownLists {
    @MainActor
    static func continueList(in textView: NSTextView) -> Bool {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else {
            return false
        }
        let lineRange = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let beforeCursor = string.substring(with: NSRange(location: lineRange.location,
                                                          length: selection.location - lineRange.location))
        guard let match = beforeCursor.firstMatch(of: /^(\s*)(?:([-*+]) \[[ xX]\] |([-*+]) |(\d{1,9})([.)]) )/) else {
            return false
        }
        let prefix = String(match.0)
        let rest = string.substring(with: NSRange(location: selection.location,
                                                  length: NSMaxRange(lineRange) - selection.location))
        if beforeCursor == prefix, rest.allSatisfy(\.isWhitespace) {
            // An empty item: take its marker away, which ends the list.
            textView.insertText("", replacementRange: NSRange(location: lineRange.location,
                                                              length: prefix.utf16.count))
            return true
        }
        let indent = String(match.1)
        let marker = if let box = match.2 {
            "\(box) [ ] "
        } else if let bullet = match.3 {
            "\(bullet) "
        } else if let number = match.4.flatMap({ Int($0) }), let delimiter = match.5 {
            "\(number + 1)\(delimiter) "
        } else {
            ""
        }
        textView.insertText("\n" + indent + marker, replacementRange: selection)
        return true
    }
}
