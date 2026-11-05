// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesAudio
import SwiftUI

/// One track's live level. The scale is in decibels, so quiet speech still moves it.
struct LevelMeterView: View {
    private static let floorDecibels: Float = -60

    let title: String
    let accessibilityName: String
    let level: Float

    private var decibels: Float {
        AudioAnalysis.decibels(level)
    }

    private var fraction: Double {
        guard decibels > Self.floorDecibels else {
            return 0
        }
        return Double(min(1, 1 - decibels / Self.floorDecibels))
    }

    private var color: Color {
        if decibels > -3 {
            return .red
        }
        return decibels > -12 ? .yellow : .green
    }

    /// Words rather than numbers, and coarse enough that VoiceOver isn't chasing every change.
    private var spokenLevel: String {
        switch decibels {
        case ..<(-60): "Silent"
        case ..<(-35): "Quiet"
        case ..<(-12): "Good"
        case ..<(-3): "Loud"
        default: "Too loud"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityName) level")
        .accessibilityValue(spokenLevel)
    }
}
