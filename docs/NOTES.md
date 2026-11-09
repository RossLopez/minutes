# Engineering notes

Spec-level decisions, and places where Apple APIs behave differently than documented.

## Decisions

### Minimum OS is macOS 27 (Nov 5, 2026)

The spec originally targeted macOS 26. Ross chose to support only macOS 27, the latest release, and `docs/BUILD_PROMPT.md` was updated to match.

- The package manifest uses `.macOS(.v27)`, which needs `swift-tools-version: 6.4`.
- CI runs on the `xcode-27` image, which runs macOS 27. The `macos-26` and `macos-latest` images are still on macOS 26.
- The Homebrew cask will use `depends_on macos: ">= :golden_gate"`.

### Apple is the default transcription engine (Nov 6, 2026)

Ross chose Apple's `SpeechTranscriber` as the default, with Parakeet TDT v2 through FluidAudio as an optional download, and left out WhisperKit. I had recommended Parakeet as the default, because it got 49 of 52 vocabulary terms against Apple's 30. `SpeechTranscriber` ignores contextual strings, so on the default engine only the replacement step after transcription helps with custom terms, and Settings says so. The numbers are in [TRANSCRIPTION_SPIKE.md](TRANSCRIPTION_SPIKE.md).

### Speaker memory is in v1 (Nov 6, 2026)

Ross moved Speaker memory from the roadmap into v1. It's built at Milestone 4, because it needs diarization's voice data and that milestone's naming UI. It's opt-in, because a voice profile is biometric data about other people, and some places regulate it. Milestone 4's planning has to confirm the diarization engine exposes speaker embeddings.

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

## Milestone 2 measurements (Nov 6, 2026)

### Player sync

Beeps of 1 kHz on Me and 3 kHz on Others, one each second, played through the real `TwoTrackPlayer` from a separate process and recorded by Minutes, with onsets measured on the result.

| Check | Result |
| --- | --- |
| 1× | The tracks' beeps land 0.0 ms apart, after a first beep about 21 ms off at the very start |
| Mute, while playing | Silences only that track, both ways round |
| 2× with `.timeDomain` | A steady 36 to 37 ms between tracks (Others after Me), and even spacing |
| 2× with `.spectral` | 22 to 56 ms and uneven onsets, so we use `.timeDomain` |
| Back to 1× and seek | 0.0 ms again |
| Seek | Beeps exactly 1.000 s apart, 0.0 ms between tracks. New audio about 0.3 to 0.4 s after the seek (an estimate, not measured precisely) |

1.25×, 1.5× and 1.75× weren't measured. Sync by ear still needs a person.

### List with 1,000 meetings

Generated folders holding only `meeting.json`, measured with temporary timing code in `LibraryStore.refresh`. The worst gap comes from a 5 ms timer on the main thread.

| Check | Result |
| --- | --- |
| Scan, off the main thread | 38 to 151 ms across five refreshes |
| Worst main-thread gap, first render | 99 ms |
| Worst main-thread gap, later refreshes | 9 to 45 ms |

That's no visible stall, so the index can wait for Milestone 8. Real meetings will have more files once transcripts exist, but the scan only reads `meeting.json`.

### Moving the library

`LibraryMover` with its real volume check and copy verification, moved to a 300 MB APFS disk image. The original went to a scratch folder instead of the Trash.

| Check | Result |
| --- | --- |
| Move of about 116 MB | 0.14 s, and `diff -r` found no differences |
| Disk image too small | Refused before copying, with both sides unchanged |
| Record in the new place | Saved there with both tracks (fake audio) |
| Unmount, then activate | List offers Locate and Use Default, and Record refuses. No folder appeared at the old path |
| Mount again, then activate | The list comes back by itself |

The file panel behind **Move…** and **Locate…** runs in another process, so no automated check here has chosen a folder through it.

## Milestone 3 measurements (Nov 6, 2026)

On the M5 Pro with 24 GB, Debug build, in the app. Engine comparison is in `docs/TRANSCRIPTION_SPIKE.md`.

**A 4-hour meeting from end to end,** with the same AMI audio on both tracks, so the mic cleans to near silence and no vocabulary list:

| | Parakeet | Apple |
| --- | --- | --- |
| Cleaning the mic track | 366 s | 362 s |
| Transcribing system audio | 102 s | 128 s |
| Whole run | 500 s | 532 s |
| Peak memory (footprint) | 396 MB | 76 MB, plus Apple's system service |
| Network connections seen | None | None |
| Lines in the transcript | 1,547 | 1,590 |

Parakeet with a vocabulary list peaked at 797 MB on 4 hours when measured through the engine alone. Cleaning is the slowest step, at about 40× real time, and memory doesn't grow with its length. Opening that transcript and playing from a line 2 hours in used 83 MB.

**Half an hour on two tracks in the app:** 18 s with Apple, 55 s with Parakeet and a one-term list.

**Killed with `kill -9` during cleaning, each transcription step in turn:** it resumed from the last finished step every time, and ended with a complete transcript and no `.processing` folder.

**Logs:** a search of the app's log and console output for phrases from these transcripts found none.

## Milestone 4 measurements (Nov 8, 2026)

On the M5 Pro with 24 GB, release build, through `minutes-diarizecheck` with FluidAudio 0.18.2's offline pyannote Community-1 pipeline. The audio is AMI's ES2004 meetings (Mix-Headset, CC BY 4.0), the same four people in four meetings, re-encoded to the system track's format: 48 kHz mono AAC at 96 kbps. The reference labels and scoring regions are pyannote's AMI-diarization-setup (`only_words`). Scored at 10 ms with the best one-to-one speaker mapping, overlapped speech included. Times are at batch 32 for single meetings and batch 8 for 4 hours.

| Meeting | Length | Speaker error | Missed | False alarm | Confused | With 0.25 s collar | Overlapped speech | Speakers found | Time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ES2004a | 17 min | 23.9% | 20.3% | 1.9% | 1.6% | 14.4% | 15.8% | 4 of 4 | 4.4 s |
| ES2004b | 39 min | 16.6% | 12.6% | 2.4% | 1.6% | 8.4% | 10.1% | 4 of 4 | 8.3 s |
| ES2004c | 39 min | 17.3% | 12.2% | 3.4% | 1.6% | 9.2% | 10.7% | 4 of 4 | 8.5 s |
| ES2004d | 37 min | 25.9% | 18.3% | 3.4% | 4.2% | 15.6% | 15.1% | 4 of 4 | 7.8 s |
| All four, twice over | 4.1 h | 20.4% | 14.8% | 2.9% | 2.7% | 11.3% | 12.0% | 5 of 4 | 73 s |

- **Most of the error is overlap.** Minutes asks for one speaker at a time (`exclusiveSegments`), so each word has one owner, and the second voice in overlapped speech always counts as missed. Words go to the wrong person only for the "Confused" share, 1.6–4.2%.
- **FluidAudio's published 15% on AMI** sits between the strict and 0.25 s collar figures here. Its scoring setup isn't stated.
- **The fifth speaker on 4 hours** has 1.1 minutes of the 204 spoken: a stray split that the merge action fixes.

**Memory and batch size,** as peak footprint (Activity Monitor's figure). The resident size is no use here: it counts the mapped 16 kHz audio, 0.9 GB for 4 hours, which the system can drop at any time.

| | Batch 32 (FluidAudio's default) | Batch 8 |
| --- | --- | --- |
| ES2004b, 39 min | 979 MB, 8.2 s | 650 MB, 10.6 s |
| 4.1 hours | 1,444 MB, 60 s | 1,008 MB, 73 s |
| Output | Identical turns | Identical turns |

The plan expected about 400 MB at batch 32 and 100 MB at batch 8, from FluidAudio's per-window figure. The rest grows with the length of the meeting. Minutes uses batch 8. The diarizer runs alone after transcription, so the pipeline's peak is the larger of the two steps, not their sum.

**Voice matching across meetings.** Each speaker in ES2004a was re-measured from all their turns (`embedSpans`), as the app will do when someone is named with memory on. The speakers in b, c and d were then compared with those four profiles by cosine similarity:

| | Pairs | Lowest | Median | Highest |
| --- | --- | --- | --- | --- |
| Same person | 12 | 0.777 | 0.929 | 0.973 |
| Different people | 36 | -0.069 | 0.091 | 0.387 |

Every speaker's best match was the right person, at least 0.42 ahead of the next. The embedding the diarizer returns and a re-measured one for the same speaker agree within 0.03, so matching can use the diarizer's without measuring again. The highest score between different people, 0.387, is the two women.

**Cutoffs chosen:** a name is applied at 0.70 or above when it's also at least 0.15 ahead of the next profile, suggested from 0.50 to 0.70, and nothing is shown below 0.50. That leaves room on both sides of what was measured, since real calls use different microphones and compression. These come from four voices on one recording setup, so they are a starting point, not a tuned value.

**Through the app, recorded live.** ES2004a (17.5 min) was played through the MacBook Pro's speakers with `afplay` while the Debug app recorded, with Apple Speech as the engine and the speaker model installed. Processing finished 55 s after Stop. The system track lined up with the source at a 5.44 s offset with an envelope correlation of 0.984, so capture adds almost nothing. Each system word was compared with the reference speaker at its midpoint, counting only words where exactly one person was talking:

| | Speakers found | Words | Given to the right speaker |
| --- | --- | --- | --- |
| Recorded through the Mac | 4 of 4 | 1,811 | 97.7% |
| Same words, diarized from the original file | 4 of 4 | 1,811 | 97.9% |

Most of the misses are short words at turn changes. With no headphones, two mic lines in 17 minutes repeated what the speakers played: the mic leak that Milestone 2 measured, not a diarization error.

## Apple API notes

Measurements are from a MacBook Pro on macOS 27.0.1 with a quiet test tone played by `afplay`, unless a note says otherwise.

### `SpeechTranscriber` ignores contextual strings (Nov 6, 2026)

With 24 terms in `AnalysisContext.contextualStrings[.general]`, `SpeechTranscriber`'s output was word-for-word identical to a run without them, whether the context was given at creation or through `setContext`. `DictationTranscriber` does use them, doubling its term hits from 16 to 32 of 52, but its overall accuracy is lower. The headers don't mention this. Full numbers are in [TRANSCRIPTION_SPIKE.md](TRANSCRIPTION_SPIKE.md).

### `.searchable` adds no ⌘F (Nov 6, 2026)

A `.searchable` field in a `NavigationSplitView` sidebar gets no Find command in the Edit menu and doesn't respond to ⌘F. We add the command ourselves and focus the field through `searchFocused`.

### `AssetInventory.status` depends on a transcriber's attribute options (Nov 6, 2026)

On macOS 27.0.1 with the English model installed, `status(forModules:)` returned `.installed` for `attributeOptions: []` and `[.audioTimeRange, .transcriptionConfidence]`, but `.supported` for `[.audioTimeRange]` alone. `assetInstallationRequest(supporting:)` returned `nil` in all three, and transcription works in all three. Minutes asks for both attributes, which is what the comparison measured, and treats `nil` from `assetInstallationRequest` as installed.

### Apple's speech engine needs no permission (Nov 6, 2026)

`SpeechTranscriber` transcribed a file in the signed, hardened app without a prompt or a usage description, so Permissions doesn't need a row for it.

### UI tests need Automation Mode (Nov 6, 2026)

`xcodebuild test` on UI tests asks macOS to turn on Automation Mode, which needs the user's authentication on this Mac. With the screen locked it fails with "System authentication is running", and if nobody answers it fails with "Timed out while enabling automation mode". Neither is a test failure.

### `fixedSize` on wrapping text can overflow the window (Nov 6, 2026)

`.fixedSize(horizontal: false, vertical: true)` on a line of text inside an `HStack` pushed the whole window's content up by about 130 pt, including the sidebar, and put the player bar out of sight. The window itself didn't change size. SwiftUI measures the minimum height with a width near zero, where each letter gets its own line, and `fixedSize` makes that the true minimum. **Workaround:** leave it off. `Text` already wraps when it's given the room.

### Echo removal and clock drift (Nov 6, 2026)

Measured on synthetic echo in `MicCleanerTests`, because a real room can't be repeated exactly. Settled echo is 37.2 dB lower, with echo found at −21.2 dB. A voice over the echo changes by −0.07 dB, and echo is 21.2 dB lower while both people talk. After a 5 ms timing jump it's 30.8 dB lower, and 29.8 dB for echo that starts late.

Drift between the tracks is the weak spot:

| Drift | Echo removed |
| --- | --- |
| 2.3 ppm (measured on this Mac's built-in devices) | 30.6 dB |
| 5 ppm | 23.3 dB |
| 10 ppm | 17.9 dB |
| 20 ppm | 9.5 dB |
| 40 ppm | 6.0 dB |

So a mic and speakers on separate clocks, like a USB headset's mic with the Mac's speakers, could fall short of the 15 dB target. Nothing in Minutes corrects drift.

### Echo through real speakers (Nov 7, 2026)

One run: 90 seconds of a public AMI meeting played by `afplay` through MacBook Pro Speakers while Minutes recorded from the built-in mic, with nobody talking. Output volume read 31% before the run and 38% after it. Nothing in the test set it, so it's unknown which applied during the recording.

| Measure, less room noise of −50.4 dBFS | Raw mic | Cleaned mic | Removed |
| --- | --- | --- | --- |
| Whole playback | −35.9 dBFS | −51.0 dBFS | 15.1 dB |
| First 25 seconds of playback | −37.1 dBFS | −48.3 dBFS | 11.2 dB |
| Settled, last 45 seconds | −35.3 dBFS | −56.8 dBFS | 21.5 dB |

| Words heard on the mic track | Raw mic | Cleaned mic |
| --- | --- | --- |
| Apple Speech | 274 | 0 |
| Parakeet | 269 | 47 in the comparison tool, 45 in the app |

- **Real echo is harder than synthetic.** Settled removal is 21.5 dB against 37.2 dB on synthetic echo, and it takes tens of seconds to settle. Don't quote `minutes-audiocheck`'s cleaned figures (−41.8 to −58.3 dB) as echo: those windows show lags of 241 to 370 ms and correlation under 0.13, so nothing aligned was found. Compare levels instead.
- **Parakeet hears words in what's left.** In the app they became 10 false Me lines between 52.5 and 82.4 s. They're garbled, and mostly don't match what was playing, so the duplicate filter proposed in the Milestone 3 plan wouldn't catch them.
- **Those words are almost as quiet as the room.** Cleaned level during them is −2.5 to 3.9 dB against room noise, with a median of 0.8 dB.

### Filtering leftover echo words (Nov 8, 2026)

A second run played the same clip at 50% volume while Ross read a script for about 25 seconds: one part in a normal voice, one quietly, one trailing off. With the louder playback, raw echo measured −15 to −19 dB and removal settled at 12 to 16 dB. Removal stayed at 4 to 6 dB while he talked over the playback, because the canceller adapts less during double talk.

`LeftoverEchoFilter` drops a phrase of mic words when its loudest word is less than 10 dB above the mic track's background and the system track had sound at that moment. Words further than 0.5 s apart are separate phrases. The background is the 10th percentile of 0.1 s block levels in the cleaned mic, leaving out digital silence. Nothing is dropped when `mic.m4a` is an exact copy of the original, or when the levels can't be read.

| Phrase's loudest word, above background | Nov 7 (echo only) | Nov 8 (echo) | Nov 8 (Ross) |
| --- | --- | --- | --- |
| Range | Up to 4.6 dB | Up to 6.4 dB | 14.7 to 17.5 dB |

| Words kept, by cutoff | 6 dB | 8 to 12 dB |
| --- | --- | --- |
| Ross's words, Apple / Parakeet | 73 of 73 / 75 of 75 | 73 of 73 / 75 of 75 |
| Echo words, Nov 8, Apple / Parakeet | 4 of 11 / 30 of 103 | 4 of 11 / 6 of 103 |
| Echo words, Nov 7, Parakeet | 0 of 47 | 0 of 47 |

The app with Parakeet and the 10 dB cutoff matched this: no Me lines on Nov 7, and only the script plus 6 echo words on Nov 8. Others kept all 268 words.

- **What gets through:** echo straight after the user stops talking joins the user's phrase. Here it added "High catching is important. It's not" to Ross's last line. Single words' levels don't separate them: Ross's quietest words were 5.9 to 6.7 dB, and the attached echo words 4.8 to 7.2. How much echo removal took from each word overlaps too, 0 to 14.3 dB for his words and 7.9 to 15.5 for the echo.
- **Not covered:** more than 50% volume, someone further from the mic than a laptop user, and any other room or Mac. Louder echo could clear the 10 dB cutoff.

### FluidAudio's lexicon isn't in the app (Nov 6, 2026)

`docs/TRANSCRIPTION_SPIKE.md` first assumed its 1 MB LuxTTS lexicon came under FluidAudio's license. It doesn't: its file says the data comes from eSpeak NG (GPL-3.0-or-later) and FrequencyWords (CC BY-SA 4.0). With traits off, Minutes doesn't link that target and the built app has no copy of it, so neither license applies to what ships. Turning on FluidAudio's `TTS` trait would change that.

### A focused field removed by selection gets no focus change first (Nov 6, 2026)

Selecting another row while a `TextField` has focus can remove the view without a useful order of events: its `onChange(of: focus)` and `onDisappear` may both run, sometimes after a rename from the first has already moved the folder. Anything saved from both must tolerate running twice, so `LibraryStore.rename` ignores a folder that has gone. Editing state also has to be cleared in `onDisappear`.

### Combined rows in UI tests (Nov 6, 2026)

A row with `.accessibilityElement(children: .combine)` appears to XCUITest as one `StaticText` whose value is all its text joined, such as `Budget Review, 8:52 AM`. Match it with `value BEGINSWITH`, not by its title as a label. XCUITest's "no matches" error can blame the parent query when it's the child that didn't match.

### UI test steps are slow on CI (Nov 6, 2026)

A single XCUITest step can take several seconds on a GitHub runner. One menu click took about 4 s, and 6.6 s passed between clicking Play and typing a new title, which outlasted the 6 s of audio left in a test recording. So checks that need audio still playing use a long meeting seeded before launch, rather than a recording timed to outlast the steps.

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

### Several `AVAssetReaderAudioMixOutput` readers can hang for good on a busy machine (Nov 8, 2026)

After Milestone 3, CI's unit tests hung until cancelled, twice. The playback tests render compositions through `AVAssetReaderAudioMixOutput`, and a stack sample showed every one blocked in `copyNextSampleBuffer`. Every CoreMedia reader thread (`readerOfflineMixer`, `audioqueue.source`, `audiomentor`) was waiting, and none was working. The same tests passed on the same runner image before Milestone 3, which added CPU-heavy tests to the same process. The runner has 3 cores.

Reproduced on an M5 Pro with every core kept busy:

| Readers at once | Cores busy | Result |
| --- | --- | --- |
| 1 | Yes | Finishes |
| 6 (the playback tests) | Yes | Finishes |
| 36 | No | Finishes in 0.4 s |
| 36 | Yes | Hangs in 5 runs of 5, and doesn't recover when the load stops |
| 36, one at a time | Yes | Finishes in about 2 s, 3 runs of 3 |

It isn't Swift's shared threads running out. 36 readers on a one-thread pool (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) finish when the CPU is free.

**Workaround:** the tests render one at a time through `RenderGate` in `PlaybackTests.swift`, and `many renders at once all finish` guards it. The app doesn't read compositions this way: playback uses `AVPlayer`. Any future code that reads several compositions at once should do the same. CI also runs the unit tests through `scripts/test-with-watchdog.sh`, which prints a stack sample if they run past 15 minutes.

### Xcode keeps a package's old traits after `Package.swift` changes them (Nov 8, 2026)

Milestone 4 changed MinutesKit's FluidAudio dependency from `traits: []` to `traits: ["Diarizer"]`. `swift build` picked up the change. Xcode 27.2, building into the existing `build/` folder, still compiled FluidAudio with no `-DDiarizer` and failed with "cannot find type 'OfflineDiarizerManager'". `xcodebuild -resolvePackageDependencies` and removing FluidAudio's intermediates didn't help.

**Workaround:** delete `build/Build/Intermediates.noindex/XCBuildData/PIFCache` after changing a package's traits, or build into a new `-derivedDataPath`. CI starts from an empty `build/` every run, so it isn't affected.

### FluidAudio's diarizer folder and loader (Nov 8, 2026)

These are FluidAudio 0.18.2 details rather than Apple's, kept here so the next upgrade checks them:

- `ModelHub.download(.diarizer, to: dir, variant: "offline")` writes to `dir/speaker-diarization` (`Repo.diarizer.folderName`), not to the Hugging Face repo name `speaker-diarization-coreml`.
- `OfflineDiarizerModels.load(from:)` takes the parent folder and adds `speaker-diarization` itself.
- Loading never deletes or re-downloads while `ModelHub.offlineMode` is on. Minutes keeps it on except during a download the user starts, so `prepareModels`, which does purge and re-download, is never called.
- Its logging goes through `AppLogger`, which hands each message to `os.Logger` as one interpolated string, so the unified log redacts it as private unless a profile says otherwise. The diarizer's messages hold the models folder path, timings and counts. Minutes passes it audio samples, never a meeting's path, so no title reaches them. The segmentation and embedding stages also write `[Profiling]` timing lines to stdout, which a GUI app's launchd discards.
