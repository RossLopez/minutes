// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import MinutesStorage
import Testing

private func newYorkCalendar() throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    return calendar
}

private func newYork(_ text: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return try #require(formatter.date(from: text))
}

@Test(arguments: [
    ("2026-11-20 00:00", MeetingSection.Period.today),
    ("2026-11-19 23:59", .yesterday),
    ("2026-11-19 00:00", .yesterday),
    ("2026-11-18 23:59", .previousSevenDays),
    ("2026-11-13 00:00", .previousSevenDays),
    ("2026-11-12 23:59", .previousThirtyDays),
    ("2026-10-21 00:00", .previousThirtyDays),
    ("2026-10-20 23:59", .month(year: 2026, month: 10)),
    ("2025-11-20 12:00", .month(year: 2025, month: 11)),
    ("2026-11-21 09:00", .today),
])
func `dates fall into the right period`(text: String, expected: MeetingSection.Period) throws {
    let period = try MeetingGrouping.period(
        of: newYork(text),
        now: newYork("2026-11-20 12:00"),
        calendar: newYorkCalendar(),
    )
    #expect(period == expected)
}

@Test func `a day with a clock change still counts as one day`() throws {
    // Clocks went back on Nov 1, 2026 in New York, so that day has 25 hours.
    let period = try MeetingGrouping.period(
        of: newYork("2026-11-01 00:30"),
        now: newYork("2026-11-02 00:10"),
        calendar: newYorkCalendar(),
    )
    #expect(period == .yesterday)
}

@Test func `sections keep their order and contents`() throws {
    let calendar = try newYorkCalendar()
    let entries = try ["2026-11-20 09:00", "2026-11-20 08:00", "2026-11-19 09:00", "2026-09-01 09:00"]
        .reversed()
        .map { text in
            try MeetingEntry(
                folder: MeetingFolder(url: URL(fileURLWithPath: "/tmp/\(text)")),
                metadata: nil,
                date: newYork(text),
            )
        }
    let sections = try MeetingGrouping.sections(for: entries, now: newYork("2026-11-20 12:00"), calendar: calendar)

    #expect(sections.map(\.period) == [.today, .yesterday, .month(year: 2026, month: 9)])
    #expect(sections.map(\.entries.count) == [2, 1, 1])
    #expect(sections[0].entries[0].date > sections[0].entries[1].date)
}

@Test func `no meetings means no sections`() {
    #expect(MeetingGrouping.sections(for: [], now: Date()).isEmpty)
}
