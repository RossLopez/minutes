# Minutes — Claude Code Build Prompt

Nov 5, 2026 · @Ross L

## How to use this prompt

Export this doc as Markdown, save it in an empty repo folder as `docs/BUILD_PROMPT.md`, then start Claude Code there and say: "Read docs/BUILD\_PROMPT.md and start with Milestone 0. Use plan mode first." Everything below this section is written to Claude Code.

Before you start, have ready: Xcode 27 on an Apple Silicon Mac, your Apple Developer Team ID, and a GitHub repo name. Signing secrets are only needed at Milestone 9.

## 1. Your role and the product

You are a senior macOS engineer building **Minutes**, a free, open source, native macOS meeting recorder for Apple Silicon. It records any meeting by capturing system audio and the microphone on separate tracks. After the meeting ends, it transcribes locally, identifies speakers, and writes an AI summary using a local model. Users name speakers after the fact, take notes during the meeting, ask an AI to clean up those notes, and chat with an AI about any past meeting.

### Non-negotiable principles

1. **Fully local and private.** Audio, transcripts, notes and summaries never leave the Mac. The only network calls allowed are: model downloads the user starts, update checks the user can turn off, and requests to a local OpenAI-compatible endpoint the user configures. No telemetry, analytics or crash reporting services.
2. **No accounts.** No sign-in, no cloud, no license keys. Open the app and it works.
3. **No meeting bots, ever.** Minutes never joins, integrates with, or automates Teams, Zoom, Meet, Webex or any other meeting app. It only captures audio from the Mac itself.
4. **Keep the originals.** Full audio files are always kept unless the user deletes the meeting.
5. **Feels like Apple made it.** Native SwiftUI, Liquid Glass, SF Symbols, standard keyboard shortcuts, system Settings scene, full dark mode and VoiceOver support. No Electron, no web views for core UI.
6. **Human-readable files.** Everything a user cares about is stored as plain files (Markdown, JSON, audio) in `~/Minutes/`, readable without the app.

## 2. Platform, stack and license

| Area | Decision |
| --- | --- |
| Minimum OS | macOS 27 Golden Gate, Apple Silicon only (arm64). No Intel build. |
| Language / UI | Swift 6 with strict concurrency, SwiftUI, Liquid Glass materials. AppKit only where SwiftUI can't do it. |
| Project | Generate the Xcode project from a checked-in `project.yml` (XcodeGen) so `.pbxproj` churn stays out of git. Swift Package Manager for dependencies. |
| Database | SQLite via GRDB, with FTS5 for full-text search. The database is an index only and must be rebuildable from the files in `~/Minutes/`. |
| Sandbox | Not sandboxed (direct distribution, not the Mac App Store). Hardened runtime on. |
| Entitlements | `com.apple.security.device.audio-input`. Add others only when a feature needs them, and say why in a comment. |
| Info.plist | `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription` with plain-language text. |
| Updates | Sparkle 2 with EdDSA-signed appcast hosted on GitHub Releases. Off-switch in Settings. Disabled automatically when installed via Homebrew. |
| License | GPL v3. Add `LICENSE`, SPDX headers in source files, and confirm every dependency's license is GPL v3 compatible before adding it. |
| Bundle ID | `io.github.<owner>.minutes` (ask me for `<owner>`). Check that the name "Minutes" doesn't collide on Homebrew; if it does, use `minutes-app` for the cask token. |

macOS 27 APIs are newer than much of your training data. Before using any audio, Speech, or Liquid Glass API, check Apple's current documentation or SDK headers. Never invent API names; if you're unsure an API exists, say so and propose a fallback.

## 3. Audio capture

Record two separate tracks for every meeting: **mic** (the local user) and **system** (everyone else). They are never mixed at capture time.

### System audio

- Use Core Audio process taps (`CATapDescription` + `AudioHardwareCreateProcessTap`, attached to a private aggregate device). Tap all system output, excluding Minutes' own process so app sounds aren't recorded.
- Do not use ScreenCaptureKit for audio unless taps prove unworkable; it pulls in the Screen Recording permission, which users find alarming for an audio app.
- Handle output device changes mid-meeting (AirPods connecting, display audio, Bluetooth handoff) without dropping the recording. Rebuild the tap and continue writing to the same file, logging the gap if there is one.

### Microphone

- Capture with `AVAudioEngine` on the user's chosen input device (default: system default input, follows changes).
- **Echo control, in two layers:**
  1. Live (optional, off by default): Apple's voice processing on the input node for echo cancellation, at minimum ducking. It can't be made duck-free, so it lowers meeting audio while on (measured in `docs/NOTES.md`).
  2. After the meeting: because Minutes has the exact system-audio signal, run a reference-based echo/bleed suppression pass on the mic track using the system track as the reference. Keep the raw mic file too; transcription uses the cleaned one.
- Add a Settings toggle to turn voice processing on (useful on speakers, at the cost of quieter meeting audio and no input device choice), and a one-line hint in the recording UI that headphones give the cleanest result.

### Files and reliability

- Write both tracks as 48 kHz mono in a crash-safe format while recording (CAF, flushed often). On stop, encode to the user's chosen format: AAC (`.m4a`, default) or ALAC lossless. Keep both tracks on one timeline from host timestamps, within 10 ms and with no build-up over time (the mic and output device run on separate clocks, so sample-exact alignment isn't possible); store the start offset in `meeting.json`.
- If the app or Mac crashes mid-recording, offer to recover the partial recording on next launch.
- Prevent idle sleep while recording. Show a live level meter for each track so the user can see both are working.
- Stop is manual only (button, menu bar, global shortcut). Warn if a recording runs past a configurable limit (default 4 hours) or disk space drops below 2 GB.

### Recording consent

On first launch, show a short, dismissible note that some places require everyone's consent to record and that the user is responsible for getting it. No legal advice, no nagging after that.

## 4. Transcription, vocabulary and speakers

Nothing is transcribed during the meeting. When the user stops recording, a processing pipeline runs in the background: **clean mic track → transcribe both tracks → diarize system track → merge → summarize**. Show per-step progress in the meeting view and send a notification when done. Processing must be cancellable and resumable, and must survive an app relaunch.

### Transcription engine

- English only for v1. Put the engine behind a `TranscriptionEngine` protocol so others can be added.
- Before committing, spike and compare three on-device options on the same 30-minute test recording (word accuracy on custom vocabulary, speed, memory): Apple's `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26), WhisperKit (English model, e.g. large-v3-turbo), and Parakeet via FluidAudio. Report results to me and recommend a default; let the user switch in Settings.
- The ASR model downloads on first run alongside the LLM, with size shown.
- Output word-level timestamps.

### Custom vocabulary

- Settings has a vocabulary list: each entry is a term (e.g. "Tanium", "BPA", "ISCM") with optional "often heard as" variants (e.g. "tan ium", "tannium").
- Apply it in every layer the engine supports: contextual strings / prompt biasing in ASR, deterministic replacement of listed variants after ASR, and as context for the LLM when summarizing and cleaning notes.
- Import/export the list as a plain text or CSV file.

### Speakers

- The mic track is always one speaker: **Me**, shown with the user's name from Settings.
- Diarize the system track on-device (FluidAudio's diarization or equivalent CoreML pipeline; no Python at runtime). Label results Speaker 1, Speaker 2, and so on.
- Merge both tracks into one transcript ordered by time, with overlap handled cleanly.
- **Naming:** in the transcript, clicking a speaker label opens a field to type a name. The name applies to every segment from that speaker, updates the summary's action-item owners, and is saved in `meeting.json`. Offer previously used names as suggestions. Allow merging two speakers (diarization split one person) and reassigning a single segment.
- Clicking any transcript line plays the audio from that moment.

## 5. Local AI

All AI features go through one `LLMProvider` protocol with two implementations: **Built-in** (model runs inside Minutes) and **OpenAI-compatible endpoint** (e.g. llama.cpp `llama-server`, LM Studio, Ollama's OpenAI API). Streaming responses everywhere.

### Built-in models (Google Gemma 4, Apache 2.0)

- Run GGUF models with llama.cpp (MIT) linked as a Swift package / XCFramework with Metal. If you find MLX Swift clearly faster for Gemma 4 on Apple Silicon, show me numbers before switching.
- First-run setup offers these downloads. **Default selection: Gemma 4 12B.**
  - Gemma 4 12B (default, best summaries and chat)
  - Gemma 4 E4B (lighter, fast on 8 GB Macs)
  - Gemma 4 E2B (smallest)
  - Gemma 4 26B A4B and 31B (advanced, for 32 GB+ Macs)
- Pull the official instruction-tuned GGUF builds from Hugging Face (Q4\_K\_M by default). Fetch file size and SHA-256 from the Hugging Face API at runtime; don't hardcode them. Show size, check free disk space, warn if the Mac's RAM is likely too small, support pause/resume, and verify the checksum.
- Downloading is never required to record. Recording and audio playback work with zero models installed.

### OpenAI-compatible endpoints

- Settings → AI Models: add one or more endpoints with name, base URL, optional API key (stored in Keychain), a model picker filled from `/v1/models`, and a **Test connection** button.
- Choose which provider/model is used for summaries, notes cleanup and chat (one default, overridable per feature).
- Warn (don't block) if the base URL isn't localhost or a private network address, since that would send meeting content off the Mac.

### Summaries

- Default template produces: an **overview paragraph**, **key points and decisions**, and **action items with owners** (using speaker names).
- Settings → Summary Templates: users can edit the default and create their own (name + prompt), and pick a template per meeting. Store templates as Markdown files in `~/Minutes/Templates/`.
- Regenerate summary on demand (e.g. after naming speakers). Keep previous versions.
- Long meetings: if the transcript exceeds the model's context, summarize in chunks then combine.

### Notes during the meeting

- A notes pane is open while recording: plain-text/Markdown editor, autosaved, each line quietly timestamped against the recording.
- **Clean up notes** button (after the meeting): the LLM rewrites the notes into tidy structured Markdown, using the transcript as context to fix names and fill shorthand. Show the result as a side-by-side diff to accept or discard. The original notes are always kept.

### Chat across meetings

- A Chat view (sidebar item) to ask questions about any past meeting, e.g. "What did we decide about the Splunk migration last month?"
- Retrieval: hybrid search over transcripts, notes and summaries using SQLite FTS5 plus local embeddings (EmbeddingGemma or Apple's on-device embeddings; vectors stored in SQLite). Filter by date range and by meeting.
- Every answer cites its sources as links to the meeting and timestamp; clicking jumps there and can play the audio.
- Also offer chat scoped to a single meeting from that meeting's view.

## 6. Storage

All user data lives in `~/Minutes/`, not Application Support. This works because the app isn't sandboxed. Never use `~/Documents` (often synced to iCloud). Settings → Storage lets the user move the folder; the app moves files and updates its pointer.

```
~/Minutes/
  Meetings/
    2026-11-05 0930 Weekly ISCM sync/
      meeting.json        # title, dates, duration, speakers + names, template, processing state
      audio/
        mic.m4a           # local user, cleaned
        mic-raw.m4a       # local user, untouched
        system.m4a        # everyone else
      transcript.json     # segments: speaker, start, end, words with timestamps
      transcript.md       # readable version with speaker names
      notes.md            # notes as typed
      notes-cleaned.md    # AI cleanup, if accepted
      summary.md          # latest summary (older versions in summaries/)
  Templates/              # summary templates (.md)
  Vocabulary.txt          # custom vocabulary, editable by hand
  Models/                 # GGUF + ASR + diarization models, excluded from Time Machine
  .minutes/
    index.sqlite          # search index + embeddings, rebuildable
    logs/
```

- Files are the source of truth; the database is a cache. Add a **Rebuild index** button in Settings.
- Set `isExcludedFromBackup` on `Models/` and `.minutes/`. Meeting folders stay in backups.
- Folder names are safe for all filesystems; renaming a meeting in the app renames its folder.
- Exports: **Markdown** (transcript, summary, notes together or separately) and **plain text / copy to clipboard**. A **Reveal in Finder** action on every meeting gives access to the audio files.
- Deleting a meeting moves its folder to the Trash, never permanent deletion.

## 7. Interface, Settings and permissions

The app should feel like a sibling of Notes and Voice Memos: calm, spacious, keyboard-friendly.

### Main window

- `NavigationSplitView`: sidebar (All Meetings, Chat, Recently Deleted link to Trash, plus a search field) → meeting list grouped by date → meeting detail.
- Meeting detail has tabs: **Summary**, **Transcript**, **Notes**, plus an audio scrubber pinned at the bottom with play/pause, speed (1×–2×), and per-track mute (Me / Others).
- Big, obvious **Record** button in the toolbar. While recording: elapsed time, two level meters, the notes pane, and Stop.
- Liquid Glass for toolbars, sidebars and the recording HUD; standard system colors and accent color; SF Symbols only.

### Menu bar

- A `MenuBarExtra` with Start/Stop recording, elapsed time, and Open Minutes. The icon changes state (and shows a red dot) while recording.
- A user-configurable global shortcut to start/stop (default ⌥⌘R).
- Recording continues if the main window is closed. Quitting while recording asks first.

### First run

Welcome → your name (used for "Me") → permissions → model download (Gemma 4 12B preselected, can skip) → consent note → done. Keep it to one screen per step, skippable where possible.

### Settings (standard `Settings` scene, tabbed)

| Tab | Contents |
| --- | --- |
| General | Your name, launch at login, menu bar icon, global shortcut, update checks on/off |
| Recording | Input device, voice processing on/off, audio format (AAC / ALAC), long-recording warning |
| Transcription | Engine and model, **Custom vocabulary** editor with import/export |
| AI Models | Built-in model manager (download, delete, set default, disk used), OpenAI-compatible endpoints, which model each feature uses |
| Summary Templates | Edit default, add/duplicate/delete templates |
| Permissions | See below |
| Storage | Folder location + Move, disk used per category, Reveal in Finder, Rebuild index |
| About | Version, GPL v3 notice, open source credits, link to GitHub |

### Permissions tab

One row per permission with an icon, a one-sentence reason, a live status badge (**Granted**, **Not requested**, **Denied**, or **Unknown** when it can't be determined), and a button that either requests it or opens the right System Settings pane.

- **Microphone:** status from `AVCaptureDevice.authorizationStatus(for: .audio)`; request with `requestAccess`.
- **System Audio Recording:** macOS has no public API to read this status directly. Determine it by creating a short-lived tap of Minutes' own process and playing a very quiet non-zero signal, since denied taps deliver zeros and true silence would look the same; show **Unknown** rather than guessing. Deep-link to Privacy & Security → Screen & System Audio Recording; verify the current URL scheme against macOS 27.
- **Notifications:** for "processing finished" alerts.
- Re-check statuses when the app becomes active. If a required permission is missing when the user hits Record, explain and link here instead of failing silently.

### Accessibility and polish

Full VoiceOver labels, Dynamic Type where macOS supports it, keyboard navigation for everything, reduced-motion support, and standard shortcuts (⌘F search, ⌘, Settings, space to play/pause in transcript).

## 8. Distribution

Releases ship as a signed, notarized DMG on GitHub Releases and as a Homebrew cask.

- **Signing:** Developer ID Application certificate from my existing Apple Developer Program account (the same membership I use for iOS). Hardened runtime, secure timestamp. Sign embedded frameworks and helpers inside-out; no `--deep`.
- **Notarization:** `xcrun notarytool submit --wait` using an App Store Connect API key, then `xcrun stapler staple` on the app and the DMG.
- **DMG:** branded background with drag-to-Applications layout (`create-dmg` or equivalent), named `Minutes-<version>-arm64.dmg`.
- **CI:** GitHub Actions on a macOS 27 Apple Silicon runner (`xcode-27`). On every PR: build, unit tests, SwiftLint/SwiftFormat. On a `v*` tag: archive, sign, notarize, staple, build DMG, generate SHA-256, create the GitHub Release with notes from the changelog, and update the Sparkle appcast. All secrets come from GitHub Actions secrets; document each one in `docs/RELEASING.md`. Make the pipeline work unsigned (ad-hoc) when secrets are absent so forks can build.
- **Homebrew:** start with my own tap (`<owner>/homebrew-tap`) with a cask that has `depends_on macos: ">= :golden_gate"`, `depends_on arch: :arm64`, `auto_updates true`, and a `zap` stanza that removes preferences and caches but **never** `~/Minutes/` (user data). Have the release workflow bump the cask's version and SHA automatically. Submit to the official `homebrew/cask` once the repo meets its notability requirements.
- **Repo hygiene:** `README.md` with screenshots, privacy statement and install instructions (DMG and `brew install --cask`), `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue/PR templates, `CHANGELOG.md`, and `THIRD_PARTY_NOTICES.md` listing every dependency and model license (Gemma 4 is Apache 2.0).

## 9. How to build it

### Milestones

Build in this order. Each milestone ends with a working app, passing tests, and a short demo note from you to me describing what to try. Stop and check in with me after each one.

0. **Scaffold:** repo, `project.yml`, GPL v3 files, CI build, `CLAUDE.md` with these rules, empty window + menu bar, Settings scene with stub tabs.
1. **Permissions + capture:** Permissions tab working; record mic and system audio to separate files with level meters; crash recovery; device switching. Verify no echo of system audio in the mic file with headphones, and document results with speakers.
2. **Library + playback:** `~/Minutes/` layout, meeting list, detail view, two-track player, rename, delete to Trash, Reveal in Finder.
3. **Transcription:** engine spike and report (section 4), then the post-meeting pipeline with progress, custom vocabulary, and click-to-play transcript.
4. **Speakers:** diarization, merged transcript, naming, merging and reassigning speakers.
5. **Built-in AI:** model download manager, llama.cpp runtime, summaries with the default template and custom templates.
6. **OpenAI-compatible endpoints:** add/test/select endpoints, per-feature model choice.
7. **Notes:** live notes pane during recording, AI cleanup with diff.
8. **Chat:** index, embeddings, hybrid search, cited answers, per-meeting chat; Markdown/plain-text export.
9. **Release:** first-run flow, signing, notarization, DMG, Sparkle, Homebrew tap, README with screenshots, v0.1.0 tag.

### Working rules

- Use plan mode before each milestone and show me the plan.
- Ask before adding any dependency; state its license and why it's needed.
- Keep audio, transcription, diarization, LLM and storage in separate Swift packages/modules with protocols at the boundaries, so engines can be swapped and tested with fakes.
- Unit-test the pipeline, storage and merging logic with short fixture audio files checked into the repo. UI-test the record → stop → transcript flow.
- Never log transcript or note content. Logs hold timings, errors and IDs only.
- When an Apple API behaves differently than documented, write it down in `docs/NOTES.md` with the workaround.
- If something in this spec turns out to be impractical, tell me and propose an alternative rather than quietly cutting it.

### Roadmap (not in v1, but don't design them out)

- **MCP server:** a local MCP server (stdio helper binary bundled in the app, e.g. `minutes-mcp`) so Claude and other MCP clients can list meetings, read transcripts, summaries and notes, and search, read-only by default, with an on/off switch and per-capability toggles in Settings. Keep the storage and search layer usable from a separate process so this is easy to add.
- **Calendar awareness:** read EventKit to suggest meeting titles and attendees as speaker names. Still no meeting bots.
- **Speaker memory:** optionally remember voice profiles so returning speakers are named automatically.
- **More exports:** PDF, SRT/VTT, DOCX.
- **Other languages:** last on the list, only if there's demand.
