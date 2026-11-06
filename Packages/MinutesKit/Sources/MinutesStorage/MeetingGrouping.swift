// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The date sections of the meeting list, the same ones Notes uses.
public struct MeetingSection: Identifiable, Equatable, Sendable {
    public enum Period: Hashable, Sendable {
        case today
        case yesterday
        case previousSevenDays
        case previousThirtyDays
        case month(year: Int, month: Int)
    }

    public let period: Period
    public let entries: [MeetingEntry]

    public var id: Period {
        period
    }
}

public enum MeetingGrouping {
    /// Groups entries into sections, newest first. A date after `now`, from a changed clock, counts as today.
    public static func sections(
        for entries: [MeetingEntry],
        now: Date,
        calendar: Calendar = .current,
    ) -> [MeetingSection] {
        var sections: [MeetingSection] = []
        var current: [MeetingEntry] = []
        var currentPeriod: MeetingSection.Period?
        for entry in entries.sorted(by: { $0.date > $1.date }) {
            let period = period(of: entry.date, now: now, calendar: calendar)
            if period != currentPeriod, let currentPeriod {
                sections.append(MeetingSection(period: currentPeriod, entries: current))
                current = []
            }
            currentPeriod = period
            current.append(entry)
        }
        if let currentPeriod {
            sections.append(MeetingSection(period: currentPeriod, entries: current))
        }
        return sections
    }

    static func period(of date: Date, now: Date, calendar: Calendar) -> MeetingSection.Period {
        // Counting calendar days, so a day with a clock change is still one day.
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now),
        ).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case 2 ... 7: return .previousSevenDays
        case 8 ... 30: return .previousThirtyDays
        default:
            let components = calendar.dateComponents([.year, .month], from: date)
            return .month(year: components.year ?? 0, month: components.month ?? 0)
        }
    }
}
