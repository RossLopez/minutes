// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesSearch

/// The sections of a meeting, chosen with the segmented control.
enum MeetingTab: String, CaseIterable, Identifiable {
    case summary
    case transcript
    case notes
    case ask

    /// The tab last chosen, for every meeting.
    static let storageKey = "meeting.tab"

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .summary: "Summary"
        case .transcript: "Transcript"
        case .notes: "Notes"
        case .ask: "Ask"
        }
    }

    /// The tab a passage of this kind is in.
    init(showing kind: SearchChunk.Kind) {
        switch kind {
        case .transcript: self = .transcript
        case .summary: self = .summary
        case .notes, .cleanedNotes: self = .notes
        }
    }

    /// Switches every meeting's view to this tab, as choosing it would.
    func choose() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}
