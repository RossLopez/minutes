// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
    import Foundation
    import MinutesAudio

    /// Stands in for real capture in UI tests, where nothing can grant audio permissions.
    /// Turned on by the `MINUTES_FAKE_AUDIO` environment variable, and absent from release builds.
    final class FakeAudioSource: AudioCaptureSource, @unchecked Sendable {
        private let frequency: Double
        private let queue = DispatchQueue(label: "io.github.rosslopez.minutes.fake-audio")
        private var timer: DispatchSourceTimer?
        private var phase = 0.0

        init(frequency: Double) {
            self.frequency = frequency
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
            let samples = (0 ..< 480).map { _ -> Float in
                phase = (phase + increment).truncatingRemainder(dividingBy: 2 * .pi)
                return Float(sin(phase)) * 0.2
            }
            ring.write(samples, hostTime: HostClock.hostTime(fromNanos: HostClock.nowNanos()))
        }
    }
#endif
