// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesSearch
import SwiftUI

/// Which meetings a chat asks about: a range of dates, and chosen meetings.
struct ChatFilterBar: View {
    let session: ChatSession

    @State private var isChoosingDates = false
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var until = Date()

    private var store: LibraryStore {
        .shared
    }

    var body: some View {
        HStack(spacing: 12) {
            Menu(DatePreset.title(for: session.filter.dates)) {
                ForEach(DatePreset.allCases) { preset in
                    Button(preset.title) {
                        session.filter.dates = preset.range()
                    }
                }
                Divider()
                Button("Custom…") {
                    isChoosingDates = true
                }
            }
            .fixedSize()
            .accessibilityLabel("Dates")
            .accessibilityValue(DatePreset.title(for: session.filter.dates))
            .accessibilityIdentifier("chatDates")
            .popover(isPresented: $isChoosingDates) {
                customDates
            }
            Menu(meetingsTitle) {
                Button("All Meetings") {
                    session.filter.meetings = nil
                }
                Divider()
                ForEach(recentMeetings, id: \.id) { meeting in
                    Toggle(meeting.title, isOn: binding(for: meeting.id))
                }
            }
            .fixedSize()
            .accessibilityLabel("Meetings")
            .accessibilityValue(meetingsTitle)
            .accessibilityIdentifier("chatMeetings")
        }
        .menuStyle(.borderlessButton)
    }

    private var customDates: some View {
        Form {
            DatePicker("From", selection: $from, displayedComponents: .date)
            DatePicker("To", selection: $until, in: from..., displayedComponents: .date)
            HStack {
                Spacer()
                Button("Cancel") {
                    isChoosingDates = false
                }
                Button("Done") {
                    let calendar = Calendar.current
                    let start = calendar.startOfDay(for: from)
                    let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: until)) ?? until
                    session.filter.dates = start ..< max(end, start.addingTimeInterval(1))
                    isChoosingDates = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private var recentMeetings: [(id: UUID, title: String)] {
        store.entries.prefix(30).compactMap { entry in
            entry.metadata.map { ($0.id, entry.title) }
        }
    }

    private var meetingsTitle: String {
        switch session.filter.meetings?.count {
        case nil, 0: "All Meetings"
        case 1: session.filter.meetings?.first.flatMap { store.entry(forMeeting: $0)?.title } ?? "1 Meeting"
        case let count?: "\(count) Meetings"
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { session.filter.meetings?.contains(id) == true },
            set: { isOn in
                var chosen = session.filter.meetings ?? []
                if isOn {
                    chosen.insert(id)
                } else {
                    chosen.remove(id)
                }
                session.filter.meetings = chosen.isEmpty ? nil : chosen
            },
        )
    }
}

/// The usual ranges, worked out from today when chosen.
enum DatePreset: String, CaseIterable, Identifiable {
    case anyTime
    case lastWeek
    case lastMonth
    case thisYear

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .anyTime: "Any Time"
        case .lastWeek: "Last 7 Days"
        case .lastMonth: "Last 30 Days"
        case .thisYear: "This Year"
        }
    }

    func range(now: Date = Date(), calendar: Calendar = .current) -> Range<Date>? {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        switch self {
        case .anyTime:
            return nil
        case .lastWeek, .lastMonth:
            let days = self == .lastWeek ? 7 : 30
            return (calendar.date(byAdding: .day, value: -days, to: tomorrow) ?? now) ..< tomorrow
        case .thisYear:
            let start = calendar.dateInterval(of: .year, for: now)?.start ?? now
            return start ..< tomorrow
        }
    }

    static func title(for range: Range<Date>?) -> String {
        guard let range else {
            return DatePreset.anyTime.title
        }
        if let preset = allCases.first(where: { $0.range() == range }) {
            return preset.title
        }
        let last = range.upperBound.addingTimeInterval(-1)
        return "\(range.lowerBound.formatted(date: .abbreviated, time: .omitted)) – "
            + last.formatted(date: .abbreviated, time: .omitted)
    }
}
