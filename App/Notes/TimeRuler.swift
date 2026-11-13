// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The margin beside the notes, with the time each line was written in small, dim digits.
final class TimeRuler: NSRulerView {
    var times: [Double?] = []
    /// Where each line starts, in UTF-16 offsets.
    var lineStarts: [Int] = [0]
    var canPlay = false
    var onPlay: (Double) -> Void = { _ in }

    private weak var textView: NSTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 52
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // Hiding a ruler from accessibility makes its scroll view's children fail to build, which
        // hides the editor too, so it stays an element with a name. The editor's context menu
        // offers to play from a line.
        setAccessibilityLabel("Line Times")
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("Not used from a nib.")
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        // No background or border, so the margin reads as part of the page.
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in _: NSRect) {
        let color: NSColor = canPlay ? .secondaryLabelColor : .tertiaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        forEachVisibleLine { line, lineRect in
            guard line < times.count, let seconds = times[line] else {
                return
            }
            let label = NSAttributedString(string: NotesTextView.label(seconds), attributes: attributes)
            let size = label.size()
            let origin = NSPoint(x: ruleThickness - size.width - 8, y: lineRect.midY - size.height / 2)
            label.draw(at: origin)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard canPlay else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        var played = false
        forEachVisibleLine { line, lineRect in
            guard !played, point.y >= lineRect.minY, point.y < lineRect.maxY, line < times.count,
                  let seconds = times[line]
            else {
                return
            }
            played = true
            onPlay(seconds)
        }
    }

    /// The time of the line holding this character.
    func time(atCharacter offset: Int) -> Double? {
        let line = line(atOffset: offset)
        return line < times.count ? times[line] : nil
    }

    private func line(atOffset offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Each paragraph on screen, with the rect of its first line in this view's coordinates.
    private func forEachVisibleLine(_ body: (Int, NSRect) -> Void) {
        guard let textView, let layout = textView.textLayoutManager,
              let content = layout.textContentManager
        else {
            return
        }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let start = layout.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY + origin.y <= visible.maxY else {
                return false
            }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let first = fragment.textLineFragments.first?.typographicBounds
                ?? CGRect(origin: .zero, size: frame.size)
            let inText = NSRect(x: 0, y: frame.minY + first.minY + origin.y, width: 1, height: first.height)
            let inRuler = convert(inText, from: textView)
            body(line(atOffset: offset), NSRect(x: 0, y: inRuler.minY, width: ruleThickness, height: inRuler.height))
            return true
        }
    }
}
