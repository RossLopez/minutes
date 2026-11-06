# Engineering notes

Spec-level decisions, and places where Apple APIs behave differently than documented.

## Decisions

### Minimum OS is macOS 27 (Nov 5, 2026)

The spec originally targeted macOS 26. Ross chose to support only macOS 27, the latest release, and `docs/BUILD_PROMPT.md` was updated to match.

- The package manifest uses `.macOS(.v27)`, which needs `swift-tools-version: 6.4`.
- CI runs on the `xcode-27` image, which runs macOS 27. The `macos-26` and `macos-latest` images are still on macOS 26.
- The Homebrew cask will use `depends_on macos: ">= :golden_gate"`.

### Voice processing is off by default (Nov 5, 2026)

The spec asked for voice processing on, with ducking off. Apple's API has no way to do that, so Ross chose to default it to off. Speaker echo is left to the post-meeting cleanup pass in Milestone 3, which has the exact system track as its reference. Settings can turn voice processing on, with a note explaining the costs. The measurements are under "Voice processing" below.

### A global shortcut with no new dependencies (Nov 5, 2026)

The shortcut uses Carbon's `RegisterEventHotKey`, which needs no Accessibility permission. Milestone 1 added no dependencies.

### The system track waits for sound before its first audio (Nov 5, 2026)

A tap delivers nothing until something on the Mac plays audio, so the system track's `startOffsetSeconds` can be many seconds, or missing if nothing played. The file is still padded to the full length. Later silence doesn't stop delivery: an 8-second pause in playback wasn't recorded as a gap.

### Tracks share a timeline instead of being sample-accurate (Nov 5, 2026)

The mic and the output device run on separate clocks, so sample-exact alignment across a meeting isn't possible. Both tracks are placed by host timestamp, with silence padded or frames dropped to correct drift. The target was under 10 ms with no build-up over time. **The offset stayed under 10 ms but did grow**, as measured under "Milestone 1 measurements" below.

Each track is corrected to within ±5 ms of the timeline, so the two can be up to about 10 ms apart in the worst case. That's a bound from the design, tested per track by a simulated 3-hour drift, not by a 3-hour recording.

### C and Objective-C on audio threads (Nov 5, 2026)

The macOS 27 SDK marks Swift as unsupported on real-time audio threads (`__SWIFT_UNAVAILABLE_MSG` on the real-time-safe `AVAudioSinkNode` initializer). Code that runs on those threads lives in the small `MinutesAudioRT` target. Everything else is Swift.

## Milestone 1 measurements

Measured on a MacBook Pro on macOS 27.0.1 with `minutes-audiocheck` and a generated signal played by `afplay`, on Nov 5, 2026. "Lag" is how far the mic trails the system track.

### Echo in the mic track

| Setup | Lag | Echo level | Correlation |
| --- | --- | --- | --- |
| AirPods Pro 3, voice processing off | Can't be measured | Not measurable | 0.008 to 0.014 |
| Speakers at 38% volume, voice processing off | 0.6 to 0.7 ms | About −21 dB | About 0.4 |
| Speakers, voice processing on | Not usable | −60.9 dB once settled | Not usable |

- With voice processing on, the first window measured −27.5 dB before the echo canceller settled.
- Voice processing on also lowered the system track from −32 to −38.1 dBFS RMS, and the mic's first audio arrived 0.70 s into the recording.
- A sound played by Minutes itself appeared in the mic at about −40 dBFS and was exact silence in the system track, so the tap's self-exclusion works.

### Drift over 30 minutes

Speakers, voice processing off, 1802.67 s, no gaps, both tracks exactly the same length.

| Signal | At the start | At the end |
| --- | --- | --- |
| Broadband | 0.8 ms | 5.0 ms |
| High-frequency noise bursts | 0.94 ms (correlation 0.856) | 5.12 ms (correlation 0.823) |

That's a real shift of about 4.2 ms over 30 minutes. It's under the 10 ms target at both ends, but the plan's "no larger at the end" isn't met.

**Pitched audio can't measure alignment.** Other audio playing on the Mac mid-recording read 6.38, 15.06, 2.12 and 6.44 ms in windows 10 s apart. The jumps are multiples of about 4.3 ms, which means periodic content lines up at several lags. The timeline didn't move back and forth, so use noise bursts for this measurement. Those same windows correlated at about −0.85, and that inverted polarity is unexplained.

### Device changes and failures

- **AirPods disconnected and reconnected mid-recording:** the same files continued at full rate, with gaps logged (mic 0.265 s and 2.16 s, system 0.247 s and 2.42 s). The lag after falling back to speakers was 0.6 ms.
- **`kill -9` mid-recording:** about 4.6 s of a real recording was recovered, with a lag of 0.8 ms. The tracks differed by 43 ms because a crash skips the final padding.
- **Chosen mic missing:** falls back to the default input with a banner.
- **Choosing a specific input:** tested only on Microsoft Teams Audio, a silent virtual device. A real USB mic is still untested.
- **Not measured:** power loss, and a real 4-hour recording. The warning is tested through its threshold logic.

## Apple API notes

Measurements are from a MacBook Pro on macOS 27.0.1 with a quiet test tone played by `afplay`, unless a note says otherwise.

### Starting can hang (Nov 5, 2026)

`AVAudioEngine.inputNode` can block with no timeout. During testing, every attempt to open an input hung for over 100 s, on the built-in mic and on a virtual device. The stack ended in `AudioDeviceCreateIOProcID`, then `HALC_ProxyIOContext::_TellServerAboutStreamUsage`, waiting on a `mach_msg` reply from the audio service. Playback and device property reads kept working, `coreaudiod` was at 0% CPU, and its logs showed nothing.

- **Trigger unknown.** The hang began after a scratch tool with no usage description tried to read a virtual input and exited without output, and after several force-kills of Minutes during recordings. Neither is proven. Five clean runs on the same virtual device afterward didn't bring it back, and neither did earlier `kill -9` tests.
- **It cleared by itself** some time in the next 90 minutes. `coreaudiod`'s start time didn't change, so it wasn't restarted.
- **Workaround:** the call can't be cancelled, so `RecordingController` alerts after 15 s and offers Keep Waiting or Quit Minutes, and Quit is always allowed while starting. The mic starts first, so system audio waits behind a stalled mic and neither track records. Tested during a real stall.
- A quit during a stalled start leaves a folder with no audio, and the next launch offers to move it to the Trash.

### A virtual input can skip time (Nov 5, 2026)

Microsoft Teams Audio, with no call running, delivers 512-frame chunks every 10.7 ms and then jumps 130 ms, about every 0.39 s. That works out to about 34.4 kHz from a device reporting 48 kHz. The built-in mic in the same code path ran at a steady 10.7 ms with no jumps. The jumps are already in the timestamps reaching the sink node, so they come from the device or the system, and Minutes pads and logs them correctly as gaps. This device is silent, so nothing audible is lost.

### Voice processing (Nov 5, 2026)

**Ducking can't be turned off.** It lowers audio before the tap, so it affects the recording as well as, very likely, what you hear.

| Setup | Tap level, RMS | Tap peak |
| --- | --- | --- |
| Voice processing off | −28.2 dBFS | 0.0731 |
| On, ducking level Min | −36.2 dBFS | 0.0291 |
| On, ducking level Default | −58.2 dBFS | 0.0023 |
| On, Min, `voiceProcessingBypassed = true` | −36.2 dBFS | 0.0291 |

- The deprecated `kAUVoiceIOProperty_DuckNonVoiceAudio` (2102) isn't exposed to Swift. Setting it by raw value returns `-10879` (`kAudioUnitErr_InvalidProperty`) and has no effect.
- With a specific input device, the setting is ignored when applied before enabling voice processing, and audio stops entirely when applied after. Tested only with a virtual device, Microsoft Teams Audio, whose silence makes the result easy to read.
- The input node reports extra identical channels: 9 on the built-in mic, 3 on AirPods Pro 3. All channels have the same RMS, so the app reads channel 0.
- AirPods Pro 3 drop to 24 kHz for both mic and output with voice processing on, and stay at 48 kHz with it off. The tap stays at 48 kHz either way.
- With built-in speakers and the same test tone, the mic track measured −45.5 dBFS off and −60.3 dBFS on. Part of that 15 dB is just the quieter playback. A steady tone isn't speech, so treat this as a rough figure.

### `AVAudioSinkNode` gets no audio unless the output side runs (Nov 5, 2026)

With voice processing off, connecting the input node to a sink node starts the engine successfully, but the sink's block is never called. Referencing `engine.mainMixerNode` with `outputVolume = 0` fixes it.

### System audio permission (Nov 5, 2026)

- `AudioDeviceStart` on a tap's aggregate device **blocks until the permission prompt is answered**, so it must never run on the main thread.
- Denied taps report success everywhere and deliver zeros, which is why a silent probe can't work. Tapping our own process while playing about −90 dBFS gives a clear answer:

| Permission | Non-zero frames at the tap | Setting `kAudioTapPropertyDescription` |
| --- | --- | --- |
| Granted | 383,488 of 383,488 | 0 |
| Denied | 0 of 383,488 | `kAudioDevicePermissionsError` |

- An aggregate device holding only the tap, with no sub-device, works, and it doesn't add the output device's input channels to the stream.
- `tccutil reset` returns `-10814` for an app bundle in `/private/tmp`, even after `lsregister`. It works from a normal folder.

### AudioFile doesn't update CAF sizes on each write (Nov 5, 2026)

`kAudioFilePropertyDeferSizeUpdates` defaults to on, and the header warns that a file may not be readable after a crash. `CAFFile.h` documents a `-1` data chunk size for files of unknown length, so `CAFTrackWriter` writes the file itself.

### Timestamps don't include device latency (Nov 5, 2026)

With both tracks placed by raw host time, the mic trailed the system track by a steady 47 ms on MacBook speakers. The devices report 15.6 ms of output latency and 30.5 ms of input latency (`kAudioDevicePropertyLatency` plus `kAudioStreamPropertyLatency`), 46.1 ms in total, and the rest is sound crossing the laptop. Adding the output latency to the system track and subtracting the input latency from the mic brought the measured lag to 0.6 ms.

- Adding `kAudioDevicePropertySafetyOffset` too would overshoot by 2 ms, so it isn't included.
- The reported latency is only as good as the device. AirPods Pro 3 reported 160 ms of output latency, then 5 ms a little later after reconnecting. **Alignment on Bluetooth can't be measured here**, because headphones don't leak into their own mic, so it may be off by up to about 150 ms.
- `AVAudioInputNode`'s `deviceID` can be a private aggregate such as `CADefaultDeviceAggregate-37411-1`. Its name means nothing to a person, so `MicCapture` asks Core Audio for the real input device.

### `AVAudioFile.read(into:)` can return early (Nov 5, 2026)

Reading a 96,000-frame CAF into a buffer that fits all of it returned 95,215 frames, then the last 785 on the next call. A 240,000-frame file split as 239,599 and 401. Nothing is lost, but one call isn't enough, so `AudioAnalysis` and `TrackEncoder` read until `framePosition` reaches `length`.

### `#expect` and C pointers (Nov 5, 2026)

An inline array passed to a C `const float *` inside `#expect(...)` gives the function a dangling pointer, so it reads garbage (a 0.75 peak read back as 1.45e-15) with no warning. Assign the call's result first, or wrap it in a Swift function that takes `[Float]`.

### `MenuBarExtra`'s title doesn't reach VoiceOver (Nov 5, 2026)

On macOS 27, `MenuBarExtra("Minutes", systemImage: "waveform")` exposes the status item to accessibility as "Audio Waveform", the symbol's name, instead of the title. The workaround is the `label:` initializer with `Image(systemName:).accessibilityLabel("Minutes")`, confirmed through the item's `AXTitle`.

### `NSAudioCaptureUsageDescription` belongs in a real Info.plist (Nov 5, 2026)

Third-party reports say Xcode's `INFOPLIST_KEY_*` build settings silently drop this key. This is untested here. To avoid the risk, the app uses a hand-written `App/Info.plist`, and `scripts/verify-bundle.sh` checks the key in the built bundle.
