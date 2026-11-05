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

### A real-time-safe mic and a global shortcut, with no new dependencies (Nov 5, 2026)

The shortcut uses Carbon's `RegisterEventHotKey`, which needs no Accessibility permission. `MinutesAudioRT` holds all real-time code. Nothing was added to the dependency list for Milestone 1.

### Tracks share a timeline instead of being sample-accurate (Nov 5, 2026)

The mic and the output device run on separate clocks, so sample-exact alignment across a meeting isn't possible. Both tracks are placed by host timestamp, with silence padded or frames dropped to correct drift. The target is under 10 ms with no build-up over time.

### C and Objective-C on audio threads (Nov 5, 2026)

The macOS 27 SDK marks Swift as unsupported on real-time audio threads (`__SWIFT_UNAVAILABLE_MSG` on the real-time-safe `AVAudioSinkNode` initializer). Code that runs on those threads lives in the small `MinutesAudioRT` target. Everything else is Swift.

## Apple API notes

All measurements are from a MacBook Pro on macOS 27.0.1 with a quiet test tone played by `afplay`.

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

### `AVAudioFile.read(into:)` can return early (Nov 5, 2026)

Reading a 96,000-frame CAF into a buffer that fits all of it returned 95,215 frames, then the last 785 on the next call. A 240,000-frame file split as 239,599 and 401. Nothing is lost, but one call isn't enough, so `AudioAnalysis` and `TrackEncoder` read until `framePosition` reaches `length`.

### `#expect` and C pointers (Nov 5, 2026)

An inline array passed to a C `const float *` inside `#expect(...)` gives the function a dangling pointer, so it reads garbage (a 0.75 peak read back as 1.45e-15) with no warning. Assign the call's result first, or wrap it in a Swift function that takes `[Float]`.

### `MenuBarExtra`'s title doesn't reach VoiceOver (Nov 5, 2026)

On macOS 27, `MenuBarExtra("Minutes", systemImage: "waveform")` exposes the status item to accessibility as "Audio Waveform", the symbol's name, instead of the title. The workaround is the `label:` initializer with `Image(systemName:).accessibilityLabel("Minutes")`, confirmed through the item's `AXTitle`.

### `NSAudioCaptureUsageDescription` belongs in a real Info.plist (Nov 5, 2026)

Third-party reports say Xcode's `INFOPLIST_KEY_*` build settings silently drop this key. This is untested here. To avoid the risk, the app uses a hand-written `App/Info.plist`, and `scripts/verify-bundle.sh` checks the key in the built bundle.
