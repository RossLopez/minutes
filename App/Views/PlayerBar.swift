// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesAudio
import SwiftUI

/// The audio scrubber pinned to the bottom of a meeting.
struct PlayerBar: View {
    let player: PlayerModel
    let isEditingText: Bool

    /// The position while dragging, so the thumb doesn't jump back between updates.
    @State private var dragPosition: Double?

    private var position: Double {
        dragPosition ?? player.state.currentTime
    }

    var body: some View {
        Group {
            if player.loadFailed {
                Label("This meeting's audio files can't be played.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("playerUnavailable")
            } else {
                controls
            }
        }
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: 18))
        .padding(12)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(MeetingFormatting.clock(position))
                    .font(.callout.monospacedDigit())
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(get: { position }, set: { dragPosition = $0 }),
                    in: 0 ... max(player.state.duration, 0.01),
                ) { isEditing in
                    if !isEditing, let dragPosition {
                        player.seek(to: dragPosition)
                        self.dragPosition = nil
                    }
                } label: {
                    Text("Position")
                }
                .labelsHidden()
                .disabled(!player.isReady)
                .accessibilityValue(MeetingFormatting.spokenTime(position))
                .accessibilityIdentifier("playerPosition")
                Text(MeetingFormatting.clock(player.state.duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Length")
                    .accessibilityValue(MeetingFormatting.spokenTime(player.state.duration))
            }
            HStack(spacing: 12) {
                TrackToggle(player: player, track: .mic, name: "Me", onIcon: "mic", offIcon: "mic.slash")
                TrackToggle(
                    player: player,
                    track: .system,
                    name: "Others",
                    onIcon: "person.2",
                    offIcon: "person.2.slash",
                )
                Spacer()
                Button(
                    player.state.isPlaying ? "Pause" : "Play",
                    systemImage: player.state.isPlaying ? "pause.fill" : "play.fill",
                ) {
                    player.togglePlayPause()
                }
                .labelStyle(.iconOnly)
                .controlSize(.large)
                .keyboardShortcut(isEditingText ? nil : KeyboardShortcut(.space, modifiers: []))
                .disabled(!player.isReady)
                .accessibilityIdentifier("playerPlayPause")
                Spacer()
                Picker("Speed", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                    ForEach(PlayerModel.speeds, id: \.self) { speed in
                        Text(MeetingFormatting.speed(speed)).tag(speed)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!player.isReady)
                .accessibilityIdentifier("playerSpeed")
            }
        }
    }
}

/// Turns one track on or off. A meeting missing that track can't turn it on.
private struct TrackToggle: View {
    let player: PlayerModel
    let track: PlaybackTrack
    let name: String
    let onIcon: String
    let offIcon: String

    private var isAudible: Bool {
        player.availableTracks.contains(track) && !player.mutedTracks.contains(track)
    }

    var body: some View {
        Toggle(isOn: Binding(get: { isAudible }, set: { player.setMuted(!$0, track: track) })) {
            Label(name, systemImage: isAudible ? onIcon : offIcon)
        }
        .toggleStyle(.button)
        .disabled(!player.availableTracks.contains(track))
        .help(isAudible ? "Mute \(name)" : "Unmute \(name)")
        .accessibilityLabel(name)
        .accessibilityValue(isAudible ? "Playing" : "Muted")
        .accessibilityIdentifier("playerTrack-\(track.rawValue)")
    }
}
