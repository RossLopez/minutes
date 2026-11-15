// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
    import AppKit
    import MinutesAudio

    /// Plays a sound through Minutes itself while recording, to check that the system track leaves
    /// it out. Turned on by the `MINUTES_TEST_SELF_SOUND` environment variable, and absent from
    /// release builds.
    @MainActor
    enum SelfSoundTest {
        private static var sound: NSSound?

        static func startIfRequested() {
            guard ProcessInfo.processInfo.environment["MINUTES_TEST_SELF_SOUND"] == "1" else {
                return
            }
            sound = NSSound(named: "Glass")
            sound?.loops = true
            sound?.play()
        }
    }

    /// Stands in for real capture in UI tests, where nothing can grant audio permissions.
    /// Turned on by the `MINUTES_FAKE_AUDIO` environment variable, and absent from release builds.
    final class FakeAudioSource: AudioCaptureSource, @unchecked Sendable {
        /// In demo mode, which side of the demo meeting this track hears.
        enum DemoSide {
            case mine, others
        }

        private let frequency: Double
        private let demoSide: DemoSide?
        private let demoLayout: [DemoContent.TimedLine]
        private let queue = DispatchQueue(label: "io.github.rosslopez.minutes.fake-audio")
        private var timer: DispatchSourceTimer?
        private var phase = 0.0
        private var framesDelivered = 0

        /// A steady tone, or with `demoSide`, one that rises and falls like speech while that side
        /// of the demo meeting is talking, and is almost silent otherwise.
        init(frequency: Double, demoSide: DemoSide? = nil) {
            self.frequency = frequency
            self.demoSide = demoSide
            demoLayout = demoSide == nil ? [] : DemoContent.layout()
        }

        func start(writingTo ring: AudioRing, events _: @escaping @Sendable (CaptureEvent) -> Void) throws {
            ring.setSampleRate(48000)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                self?.deliver(to: ring)
            }
            timer.resume()
            self.timer = timer
        }

        func stop() {
            queue.sync {
                timer?.cancel()
                timer = nil
            }
        }

        private func deliver(to ring: AudioRing) {
            let increment = 2 * Double.pi * frequency / 48000
            let amplitude = Float(demoSide.map(demoAmplitude) ?? 0.2)
            let samples = (0 ..< 480).map { _ -> Float in
                phase = (phase + increment).truncatingRemainder(dividingBy: 2 * .pi)
                return Float(sin(phase)) * amplitude
            }
            framesDelivered += samples.count
            ring.write(samples, hostTime: HostClock.hostTime(fromNanos: HostClock.nowNanos()))
        }

        /// Syllable-like bursts while this side talks, and a faint room tone between.
        private func demoAmplitude(_ side: DemoSide) -> Double {
            let seconds = Double(framesDelivered) / 48000
            guard let code = DemoContent.speaker(at: seconds, in: demoLayout),
                  (code == "me") == (side == .mine)
            else {
                return 0.003
            }
            let syllables = 0.45 + 0.55 * abs(sin(2 * .pi * 3.3 * seconds))
            let phrase = 0.75 + 0.25 * sin(2 * .pi * 0.6 * seconds)
            return 0.3 * syllables * phrase
        }
    }
#endif
