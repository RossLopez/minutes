// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesLLM
@testable import MinutesSearch
import Testing

@Test func `cleaning an answer drops invented citations and keeps real ones`() {
    #expect(Citations.cleaned("Due Friday [1][3]. Owned by Dana [9]. Agreed [2, 7].", count: 3)
        == "Due Friday [1, 3]. Owned by Dana. Agreed [2].")
    #expect(Citations.cleaned("No citations here.", count: 2) == "No citations here.")
}

private let meeting = UUID(uuidString: "6F1E2D3C-0000-4000-8000-000000000001")!

private func source(_ number: Int, kind: SearchChunk.Kind = .transcript, start: Double? = 724) -> ChatSource {
    ChatSource(number: number, meetingID: meeting, meetingTitle: "Budget · Review",
               meetingDate: Date(timeIntervalSince1970: 1_800_000_000), kind: kind, start: start,
               text: "Dana: Numbers by Friday.\nMe: Thanks.")
}

// MARK: - Citations

@Test func `citations become pieces, and invented numbers are dropped`() {
    let pieces = Citations.pieces(of: "Bea owns it [1, 3]. Friday [2][9]. Done [7].", count: 3)
    #expect(pieces == [
        .text("Bea owns it "), .source(1), .source(3), .text(". Friday "), .source(2), .text(". Done."),
    ])
    #expect(Citations.cited(in: "a [2] b [1] c [2]", count: 2) == [2, 1])
    // Not citations: Markdown links, checkboxes, years in brackets.
    #expect(Citations.pieces(of: "See [notes](x) and [ ] and [2026]", count: 3)
        == [.text("See [notes](x) and [ ] and [2026]")])
    #expect(Citations.removing(from: "Bea owns it [1, 3]. Friday [2].") == "Bea owns it. Friday.")
}

// MARK: - Links and files

@Test func `meeting links round-trip, and only open a place`() throws {
    let link = MeetingLink(meetingID: meeting, seconds: 724.9, kind: .notes)
    #expect(link.url.absoluteString == "minutes://meeting/\(meeting.uuidString)?t=724&kind=notes")
    #expect(MeetingLink(url: link.url) == MeetingLink(meetingID: meeting, seconds: 724, kind: .notes))
    #expect(try MeetingLink(url: #require(URL(string: "minutes://meeting/nope"))) == nil)
    #expect(try MeetingLink(url: #require(URL(string: "https://meeting/\(meeting.uuidString)"))) == nil)
    let negative = try #require(URL(string: "minutes://meeting/\(meeting.uuidString)?t=-5&kind=other"))
    #expect(MeetingLink(url: negative) == MeetingLink(meetingID: meeting, seconds: 0, kind: .transcript))
}

@Test func `a chat is saved as Markdown and read back`() {
    let created = Date(timeIntervalSince1970: 1_800_000_000)
    let chat = ChatDocument(
        title: "Budget owner",
        createdAt: created,
        model: "builtin:gemma-4-12b",
        scope: .meeting(meeting),
        filter: SearchFilter(dates: created ..< created.addingTimeInterval(86400), meetings: [meeting]),
        turns: [
            ChatTurn(
                question: "Who owns the budget?",
                answer: "Dana [1].",
                sources: [source(1), source(2, kind: .summary, start: nil)],
            ),
            ChatTurn(question: "When?", answer: "Friday.\n\nSources:\n\nNot a list."),
        ],
    )
    let text = ChatFile.markdown(chat)
    #expect(text
        .contains("## You\n\nWho owns the budget?\n\n## Minutes\n\nDana [1].\n\nSources:\n\n1. [Budget · Review · "))
    #expect(text
        .contains("](minutes://meeting/\(meeting.uuidString)?t=724)\n   > Dana: Numbers by Friday. Me: Thanks."))
    var read = ChatFile.read(text)
    #expect(read.id == chat.id)
    #expect(read.createdAt == created)
    #expect(read.scope == chat.scope)
    #expect(read.filter == chat.filter)
    #expect(read.title == "Budget owner")
    #expect(read.turns.map(\.question) == ["Who owns the budget?", "When?"])
    #expect(read.turns[1].answer == "Friday.\n\nSources:\n\nNot a list.")
    let sources = read.turns[0].sources
    #expect(sources.map(\.meetingTitle) == ["Budget · Review", "Budget · Review"])
    #expect(sources.map(\.kind) == [.transcript, .summary])
    #expect(sources.map(\.start) == [724, nil])
    #expect(sources[0].text == "Dana: Numbers by Friday. Me: Thanks.")
    #expect(Calendar.current.isDate(sources[0].meetingDate, inSameDayAs: source(1).meetingDate))
    read.turns[0].id = chat.turns[0].id
    #expect(read.turns[0].citedSources.map(\.number) == [1])
}

@Test func `a chat edited by hand keeps what it can't place`() {
    let read = ChatFile.read("Some thoughts first.\n\n## Minutes\n\nAn answer with no question.\n")
    #expect(read.turns.map(\.question) == ["Some thoughts first."])
    #expect(read.turns.map(\.answer) == ["An answer with no question."])
    #expect(read.scope == .library)
}

@Test func `chats are saved under their title, and a rename moves the file`() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Chats-\(UUID())")
    var chat = ChatDocument(createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                            turns: [ChatTurn(question: "Who owns the budget?", answer: "Dana.")])
    let first = try ChatFiles.save(chat, in: folder, replacing: nil)
    #expect(first.lastPathComponent.hasSuffix(" Who owns the budget.md"))
    #expect(try ChatFiles.save(chat, in: folder, replacing: first) == first)
    chat.title = "Budget"
    let renamed = try ChatFiles.save(chat, in: folder, replacing: first)
    #expect(renamed.lastPathComponent.hasSuffix(" Budget.md"))
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(ChatFiles.list(in: folder).map(\.chat.title) == ["Budget"])
}

@Test func `titles come from the first question, cut at a word`() {
    #expect(ChatDocument.title(from: "  Who owns the budget?\nmore") == "Who owns the budget?")
    #expect(ChatDocument.title(from: "") == "New Chat")
    let long = ChatDocument.title(from: String(repeating: "budget ", count: 20))
    #expect(long.hasSuffix("budget…"))
    #expect(long.count <= 61)
}

// MARK: - Prompts

@Test func `sources are numbered with their meeting, day and place`() {
    let utc = TimeZone.gmt
    #expect(ChatPrompts.block(source(2), timeZone: utc)
        ==
        "[2] Budget · Review, Friday, January 15, 2027 (at 12:04, transcript)\nDana: Numbers by Friday.\nMe: Thanks.")
    #expect(ChatPrompts.block(source(1, kind: .notes, start: 61), timeZone: utc).contains("(notes typed at 1:01)"))
    let messages = ChatPrompts.messages(
        history: [ChatTurn(question: "Who?", answer: "Dana [1]."), ChatTurn(question: "Unanswered")],
        question: "When?",
        sources: [source(1)],
        today: Date(timeIntervalSince1970: 1_800_000_000),
        timeZone: utc,
    )
    #expect(messages.map(\.role) == [.system, .user, .assistant, .user])
    #expect(messages[0].content.contains("Today is Friday, January 15, 2027."))
    #expect(messages[2].content == "Dana.")
    #expect(messages[3].content.hasPrefix("Sources:\n\n[1] Budget · Review"))
    #expect(messages[3].content.hasSuffix("\n\nQuestion: When?"))
}

// MARK: - Answering

private func index(with fixture: FixtureLibrary) async throws -> SearchIndex {
    try fixture.addMeeting("Kickoff", lines: [
        "me|0|" + filler(150, tag: "intro"), "speaker-1|60|the remote needs rubber buttons " + filler(60, tag: "x"),
    ], summary: "## Decisions\nRubber buttons.", names: ["speaker-1": "Dana"])
    try fixture.addMeeting("Review", on: Date(timeIntervalSince1970: 1_800_100_000), lines: [
        "me|0|budget numbers come on friday", "speaker-1|5|Bea owns the budget",
    ])
    let index = try SearchIndex(file: fixture.indexFile)
    _ = try await index.update(library: fixture.library)
    return index
}

@Test func `an answer gets the best sources that fit, numbered`() async throws {
    let fixture = try FixtureLibrary()
    let index = try await index(with: fixture)
    let provider = FakeLLMProvider(contextLength: 32768) { _ in "Bea [1]." }
    let answerer = ChatAnswerer(index: index, provider: provider, embedder: FakeEmbeddingProvider())
    let prepared = try await answerer.prepare("Who owns the budget?", history: [], scope: .library, filter: .everything)
    #expect(prepared.sources.first?.meetingTitle == "Review")
    #expect(prepared.sources.map(\.number) == Array(1 ... prepared.sources.count))
    #expect(prepared.options.maxTokens == 2048)
    var answer = ""
    for try await piece in answerer.answer(prepared) {
        answer += piece
    }
    #expect(answer == "Bea [1].")
}

@Test func `a small context drops old turns and sources, never the question`() async throws {
    let fixture = try FixtureLibrary()
    let index = try await index(with: fixture)
    // The fake counts a token per four characters: room for the rules, the question and a source or so.
    let provider = FakeLLMProvider(contextLength: 1024 + 600)
    let answerer = ChatAnswerer(index: index, provider: provider, embedder: nil)
    let history = (1 ... 6).map { ChatTurn(question: "Earlier \($0) " + filler(40), answer: filler(40)) }
    let prepared = try await answerer.prepare("rubber buttons budget", history: history, scope: .library,
                                              filter: .everything)
    #expect(prepared.droppedTurns > 0)
    #expect(!prepared.sources.isEmpty)
    let total = try await provider.tokenCount(prepared.messages)
    #expect(total + prepared.options.maxTokens <= 1624)
    #expect(prepared.messages.last?.content.hasSuffix("Question: rubber buttons budget") == true)
}

@Test func `a follow-up is searched with the question before it`() async throws {
    let fixture = try FixtureLibrary()
    let index = try await index(with: fixture)
    let answerer = ChatAnswerer(index: index, provider: FakeLLMProvider(), embedder: nil)
    let history = [ChatTurn(question: "What about the rubber buttons?", answer: "Dana wants them [1].")]
    let prepared = try await answerer.prepare("And when was that?", history: history, scope: .library,
                                              filter: .everything)
    #expect(prepared.sources.first?.meetingTitle == "Kickoff")
}

@Test func `a meeting's Ask tab sends its whole text when it fits, and its best passages when not`() async throws {
    let fixture = try FixtureLibrary()
    let index = try await index(with: fixture)
    let kickoff = try #require(try await index.matchingMeetings("rubber").first?.meetingID)
    let all = try await index.passages(of: kickoff)
    let roomy = ChatAnswerer(index: index, provider: FakeLLMProvider(), embedder: nil)
    let whole = try await roomy.prepare("rubber", history: [], scope: .meeting(kickoff), filter: .everything)
    #expect(whole.sources.map(\.text) == all.map(\.chunk.text))

    let tight = ChatAnswerer(index: index, provider: FakeLLMProvider(contextLength: 1024 + 450), embedder: nil)
    let part = try await tight.prepare("rubber", history: [], scope: .meeting(kickoff), filter: .everything)
    #expect(!part.sources.isEmpty)
    #expect(part.sources.count < all.count)
    #expect(part.sources.allSatisfy { $0.meetingID == kickoff })
    #expect(part.sources[0].text.localizedCaseInsensitiveContains("rubber"))
}
