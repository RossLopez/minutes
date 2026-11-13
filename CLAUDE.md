# Minutes

A free, open source, native macOS meeting recorder for Apple Silicon. The full spec is [docs/BUILD_PROMPT.md](docs/BUILD_PROMPT.md); read the relevant section before starting a milestone. Apple API surprises and spec-level decisions go in [docs/NOTES.md](docs/NOTES.md).

## Non-negotiable principles

1. **Fully local and private.** Audio, transcripts, notes and summaries never leave the Mac. The only network calls allowed are model downloads the user starts, update checks the user can turn off, and requests to an OpenAI-compatible endpoint the user configures. An endpoint outside the user's network must use https, is confirmed with a warning when it's saved, and is marked wherever it's chosen. No telemetry, analytics or crash reporting services.
2. **No accounts.** No sign-in, no cloud, no license keys.
3. **No meeting bots, ever.** Minutes never joins, integrates with or automates any meeting app. It only captures audio from the Mac itself.
4. **Keep the originals.** Full audio files are kept unless the user deletes the meeting.
5. **Feels like Apple made it.** Native SwiftUI, Liquid Glass, SF Symbols, standard shortcuts, system Settings scene, full dark mode and VoiceOver support. No Electron, no web views for core UI.
6. **Human-readable files.** Everything a user cares about is stored as plain files in `~/Minutes/`, readable without the app.

## Working rules

- Use plan mode before each milestone and show the plan. Stop and check in after each milestone with a short demo note.
- Ask before adding any dependency. State its license and why it's needed. Every dependency must be GPL v3 compatible.
- Keep audio, transcription, diarization, LLM and storage in separate modules with protocols at the boundaries, so engines can be swapped and tested with fakes. `MinutesStorage` must not import SwiftUI or AppKit, so a separate process can use it later.
- Code that runs on a real-time audio thread goes in the `MinutesAudioRT` C/Objective-C target: no Swift, allocation or locks there. Everything else is Swift.
- Unit-test the pipeline, storage and merging logic with short fixture audio files in the repo. UI-test the record → stop → transcript flow.
- Never log transcript or note content. Logs hold timings, errors and IDs only.
- macOS 27 APIs are newer than much of your training data. Check SDK headers or Apple's current docs before using any audio, Speech or Liquid Glass API. Never invent API names.
- When an Apple API behaves differently than documented, write it down in `docs/NOTES.md` with the workaround.
- If part of the spec turns out to be impractical, say so and propose an alternative. Don't quietly cut it.
- Every source file, including C and Objective-C, starts with `// SPDX-License-Identifier: GPL-3.0-or-later`.

## Platform

macOS 27 or later, arm64 only, Swift 6 with strict concurrency. Not sandboxed, hardened runtime on. Add an entitlement only when a feature needs it, with a comment saying why. Use real keys in `App/Info.plist` rather than `INFOPLIST_KEY_*` build settings.

## Commands

The Xcode project is generated from `project.yml` and isn't checked in. Regenerate it after adding files or changing `project.yml`.

```bash
xcodegen generate
```

```bash
xcodebuild build -project Minutes.xcodeproj -scheme Minutes -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
```

```bash
swift test --package-path Packages/MinutesKit
```

```bash
xcodebuild test -project Minutes.xcodeproj -scheme Minutes -destination 'platform=macOS,arch=arm64' -derivedDataPath build -only-testing:MinutesUITests
```

```bash
swiftformat --lint . && swiftlint --strict
```

```bash
scripts/verify-bundle.sh build/Build/Products/Debug/Minutes.app
```

`swift run --package-path Packages/MinutesKit minutes-audiocheck <meeting folder>` measures a recording: lengths, levels, track offset and how much system audio leaked into the mic.

Builds are ad-hoc signed unless `Config/Local.xcconfig` exists. See `Config/Local.xcconfig.example`.
