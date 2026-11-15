# Contributing to Minutes

Thanks for helping. Bug reports, ideas, documentation and code are all welcome. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Before you start

- **Bugs:** [open an issue](https://github.com/RossLopez/minutes/issues/new/choose) with the bug template. Say what you did, what happened and what you expected, with your Mac model and macOS version. Please don't attach recordings, transcripts or notes from real meetings.
- **Security problems:** don't open an issue. [SECURITY.md](SECURITY.md) says how to report them privately.
- **Bigger changes:** open an issue first, so we can agree on the approach before you put time in.

## The principles

Every change has to keep these. They're the reason Minutes exists.

1. **Fully local and private.** Audio, transcripts, notes and summaries never leave the Mac. The only network calls are model downloads the user starts, update checks the user can turn off, and an OpenAI-compatible server the user adds. No telemetry, analytics or crash reporting.
2. **No accounts.** No sign-in, no cloud, no license keys.
3. **No meeting bots, ever.** Minutes never joins, integrates with or automates a meeting app. It only captures audio from the Mac itself.
4. **Keep the originals.** Full audio is kept until the user deletes the meeting.
5. **Feels like Apple made it.** Native SwiftUI, SF Symbols, standard shortcuts, dark mode and VoiceOver. No web views for core UI.
6. **Human-readable files.** What users care about is plain files in `~/Minutes`.

[CLAUDE.md](CLAUDE.md) has the full working rules, and [docs/BUILD_PROMPT.md](docs/BUILD_PROMPT.md) the full spec.

## Building and testing

You need a Mac with Apple silicon, macOS 27, Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) and [SwiftLint](https://github.com/realm/SwiftLint).

The Xcode project is generated from `project.yml` and isn't checked in. Generate it again after adding files:

```bash
xcodegen generate
```

```bash
xcodebuild build -project Minutes.xcodeproj -scheme Minutes -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
```

The package tests cover the pipeline, storage, merging and search, with short fixture audio files:

```bash
swift test --package-path Packages/MinutesKit
```

The UI tests drive the app with fake audio, transcription and models, in a throwaway library, so they never touch your own `~/Minutes`. They need the screen to themselves while they run:

```bash
xcodebuild test -project Minutes.xcodeproj -scheme Minutes -destination 'platform=macOS,arch=arm64' -derivedDataPath build -only-testing:MinutesUITests
```

Lint before you push:

```bash
swiftformat --lint . && swiftlint --strict
```

`scripts/make-screenshots.sh` takes the README's screenshots again, from a made-up demo library.

## Writing code

- Start every source file, including C and Objective-C, with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- Swift 6 with strict concurrency. Code that runs on a real-time audio thread goes in the `MinutesAudioRT` target, in C or Objective-C, with no allocation or locks.
- Keep audio, transcription, diarization, LLM and storage in their own modules, with protocols at the boundaries so they can be tested with fakes. `MinutesStorage` must not import SwiftUI or AppKit.
- **Never log transcript, note, summary or chat content.** Logs hold timings, errors and IDs only.
- Add a test with the change: a package test for logic, a UI test for a new flow.
- New dependencies need a discussion first. Every dependency must be compatible with the GPL v3, and goes in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- When an Apple API behaves differently than its documentation says, write it down in [docs/NOTES.md](docs/NOTES.md) with the workaround.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.

## Pull requests

Keep a pull request to one change, and fill in the template. CI builds the app, runs the package tests, lints, checks the app bundle and builds a DMG. By contributing, you agree that your work is licensed under the [GNU General Public License, version 3 or later](LICENSE).
