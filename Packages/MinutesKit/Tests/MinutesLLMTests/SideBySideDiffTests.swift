// SPDX-License-Identifier: GPL-3.0-or-later

@testable import MinutesLLM
import Testing

private typealias Segment = SideBySideDiff.Segment

@Test func `identical text has only unchanged rows`() {
    let diff = SideBySideDiff(old: "a\nb\n", new: "a\nb")
    #expect(diff.rows.map(\.kind) == [.unchanged, .unchanged])
    #expect(!diff.hasChanges)
    #expect(diff.rows[0].left == [Segment("a", isChanged: false)])
}

@Test func `added and removed lines sit on one side`() {
    let diff = SideBySideDiff(old: "a\nold\nc", new: "a\nc\nnew")
    #expect(diff.rows.map(\.kind) == [.unchanged, .removed, .unchanged, .added])
    #expect(diff.rows[1].right == nil)
    #expect(diff.rows[3].left == nil)
    #expect(diff.rows[3].right == [Segment("new", isChanged: true)])
}

@Test func `an edited line marks the words that changed`() {
    let diff = SideBySideDiff(old: "budget - bea wants numbers fri", new: "Budget - Bea wants numbers by Friday")
    #expect(diff.rows.count == 1)
    let row = diff.rows[0]
    #expect(row.kind == .changed)
    #expect(row.left == [
        Segment("budget", isChanged: true), Segment(" - ", isChanged: false), Segment("bea", isChanged: true),
        Segment(" wants numbers ", isChanged: false), Segment("fri", isChanged: true),
    ])
    #expect(row.right == [
        Segment("Budget", isChanged: true), Segment(" - ", isChanged: false), Segment("Bea", isChanged: true),
        Segment(" wants numbers ", isChanged: false), Segment("by Friday", isChanged: true),
    ])
}

@Test func `segments put each line back together exactly`() {
    let diff = SideBySideDiff(old: "one  two\tthree", new: "one two  three four")
    let row = diff.rows[0]
    #expect(row.left?.map(\.text).joined() == "one  two\tthree")
    #expect(row.right?.map(\.text).joined() == "one two  three four")
}

@Test func `a rewritten line is marked whole`() {
    let diff = SideBySideDiff(old: "remote: rubber? ask chris", new: "## Remote control design")
    #expect(diff.rows[0].kind == .changed)
    #expect(diff.rows[0].left == [Segment("remote: rubber? ask chris", isChanged: true)])
    #expect(diff.rows[0].right == [Segment("## Remote control design", isChanged: true)])
}

@Test func `a full rewrite pairs lines and keeps the extras`() {
    let diff = SideBySideDiff(old: "x\ny", new: "## A\n- one\n- two")
    #expect(diff.rows.map(\.kind) == [.changed, .changed, .added])
}

@Test func `blank lines line up`() {
    let diff = SideBySideDiff(old: "a\n\nb", new: "a\n\nb\n\nc")
    #expect(diff.rows.map(\.kind) == [.unchanged, .unchanged, .unchanged, .added, .added])
}

@Test func `empty text on either side`() {
    #expect(SideBySideDiff(old: "", new: "").rows.isEmpty)
    #expect(SideBySideDiff(old: "", new: "a\nb").rows.map(\.kind) == [.added, .added])
    #expect(SideBySideDiff(old: "a", new: "  \n").rows.map(\.kind) == [.removed])
}
