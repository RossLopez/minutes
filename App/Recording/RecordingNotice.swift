// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesAudio

/// Something the user should see during or after a recording.
struct RecordingNotice: Identifiable, Equatable {
    enum Kind {
        case info
        case warning
    }

    let id: String
    let kind: Kind
    let text: String

    init(id: String, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }

    /// What to say about a source's event.
    init(event: CaptureEvent, track: RecordingTrack) {
        let name = track == .mic ? "microphone" : "system audio"
        switch event {
        case let .restarted(deviceName):
            self.init(
                id: "restart-\(track.rawValue)",
                kind: .info,
                text: "Now recording \(name) from \(deviceName).",
            )
        case .fellBackToDefaultInput:
            self.init(
                id: "fallback",
                kind: .warning,
                text: "Your chosen microphone isn't available, so Minutes switched to the default input.",
            )
        case .retrying:
            self.init(
                id: Self.retryID(track),
                kind: .warning,
                text: "Waiting for the \(name) device to come back. The recording continues.",
            )
        case .failed:
            let other = track == .mic ? "System audio" : "The microphone"
            self.init(
                id: "failed-\(track.rawValue)",
                kind: .warning,
                text: "The \(name) track stopped recording. \(other) is still recording.",
            )
        }
    }

    static func retryID(_ track: RecordingTrack) -> String {
        "retry-\(track.rawValue)"
    }
}

/// What's currently being shown, one notice per subject.
struct RecordingNotices: Equatable {
    private(set) var items: [RecordingNotice] = []

    var isEmpty: Bool {
        items.isEmpty
    }

    mutating func add(_ notice: RecordingNotice) {
        if let index = items.firstIndex(where: { $0.id == notice.id }) {
            if items[index] != notice {
                items[index] = notice
            }
        } else {
            items.append(notice)
        }
    }

    mutating func removeInfo() {
        items.removeAll { $0.kind == .info }
    }

    mutating func apply(_ event: CaptureEvent, on track: RecordingTrack) {
        if case .restarted = event {
            items.removeAll { $0.id == RecordingNotice.retryID(track) }
        }
        add(RecordingNotice(event: event, track: track))
    }

    mutating func apply(_ warnings: RecordingWarnings) {
        set(.pastLimit, active: warnings.pastLimit)
        set(.lowDisk, active: warnings.lowDisk)
    }

    private mutating func set(_ notice: RecordingNotice, active: Bool) {
        if active {
            add(notice)
        } else {
            items.removeAll { $0.id == notice.id }
        }
    }
}

extension RecordingNotice {
    static let pastLimit = RecordingNotice(
        id: "limit",
        kind: .warning,
        text: "This recording has run past your time limit. It keeps going until you stop it.",
    )
    static let lowDisk = RecordingNotice(
        id: "disk",
        kind: .warning,
        text: "Less than 2 GB of disk space is left. The recording keeps going until you stop it.",
    )
    static let systemAudioUnconfirmed = RecordingNotice(
        id: "system-unknown",
        kind: .warning,
        text: "Minutes couldn't confirm System Audio access. Check that the System meter moves during the meeting.",
    )
    static let encodingFailed = RecordingNotice(
        id: "encode",
        kind: .warning,
        text: "Minutes couldn't finish saving this recording. The audio is safe, and Minutes will retry next launch.",
    )
}
