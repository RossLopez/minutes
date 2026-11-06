// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesStorage

extension MeetingSection.Period {
    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previousSevenDays: "Previous 7 Days"
        case .previousThirtyDays: "Previous 30 Days"
        case let .month(year, month):
            Calendar.current.date(from: DateComponents(year: year, month: month))?
                .formatted(.dateTime.month(.wide).year()) ?? ""
        }
    }

    /// Today and yesterday are already in the section title, so their rows need only the time.
    func dateText(for date: Date) -> String {
        switch self {
        case .today, .yesterday: date.formatted(date: .omitted, time: .shortened)
        default: date.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

enum MeetingFormatting {
    /// Like `43 min` or `1 hr, 12 min`.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds else {
            return nil
        }
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = seconds < 60 ? [.seconds] : [.hours, .minutes]
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: allowed, width: .abbreviated))
    }

    /// Like `1:05` or `1:02:45`.
    static func clock(_ seconds: Double) -> String {
        let duration = Duration.seconds(max(seconds, 0).rounded(.down))
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    /// What VoiceOver reads for a position in the audio.
    static func spokenTime(_ seconds: Double) -> String {
        Duration.seconds(max(seconds, 0).rounded(.down))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    static func speed(_ speed: Float) -> String {
        "\(speed.formatted())×"
    }
}

/// What a row and the detail view show, depending on what's happening to the meeting.
enum MeetingDisplayState: Equatable {
    case ready
    case recording
    case saving
    case notFinished
    case unreadable

    @MainActor
    init(entry: MeetingEntry) {
        guard let metadata = entry.metadata else {
            self = .unreadable
            return
        }
        let isActive = RecordingController.shared.activeFolder == entry.id
        switch metadata.state {
        case .complete: self = .ready
        case .recording: self = isActive ? .recording : .notFinished
        case .encoding: self = isActive ? .saving : .notFinished
        }
    }

    var badge: String? {
        switch self {
        case .ready: nil
        case .recording: "Recording"
        case .saving: "Saving…"
        case .notFinished: "Not finished"
        case .unreadable: "Can't read"
        }
    }
}
