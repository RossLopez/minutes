// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The elapsed time, meters and Stop button shown over the window while recording.
struct RecordingHUD: View {
    let controller: RecordingController

    private var elapsedText: String {
        Duration.seconds(controller.elapsedSeconds).formatted(.time(pattern: .hourMinuteSecond))
    }

    private var spokenElapsed: String {
        Duration.seconds(controller.elapsedSeconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.red)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(elapsedText)
                        .font(.title3.monospacedDigit())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording")
                .accessibilityValue(spokenElapsed)

                VStack(spacing: 6) {
                    LevelMeterView(title: "Mic", accessibilityName: "Microphone", level: controller.micLevel)
                    LevelMeterView(title: "System", accessibilityName: "System audio", level: controller.systemLevel)
                }

                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    controller.stopRecording()
                }
                .accessibilityIdentifier("stopRecording")
            }

            ForEach(controller.notices.items) { notice in
                NoticeRow(notice: notice)
            }

            Text("Headphones give the cleanest recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: 480)
        .glassEffect(in: .rect(cornerRadius: 18))
    }
}

/// Saving progress, the confirmation afterwards, and anything left to say.
struct RecordingStatusBanner: View {
    let controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.phase == .saving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                }
            }
            if controller.lastSavedFolder != nil {
                HStack(spacing: 10) {
                    Label("Recording saved", systemImage: "checkmark.circle.fill")
                        .accessibilityIdentifier("recordingSaved")
                    Spacer()
                    Button("Reveal in Finder") {
                        controller.revealLastSaved()
                    }
                    Button("Dismiss", systemImage: "xmark") {
                        controller.dismissSavedBanner()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            ForEach(controller.notices.items) { notice in
                NoticeRow(notice: notice)
            }
        }
        .padding(14)
        .frame(maxWidth: 480)
        .glassEffect(in: .rect(cornerRadius: 18))
    }
}

private struct NoticeRow: View {
    let notice: RecordingNotice

    var body: some View {
        Label {
            Text(notice.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: notice.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(notice.kind == .warning ? .yellow : .secondary)
                .accessibilityHidden(true)
        }
    }
}
