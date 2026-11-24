# Changelog

All notable changes to Minutes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- An Appearance setting in Settings › General, to keep Minutes light or dark whatever your Mac is set to. It follows the Mac until you change it.

## [0.3.0] - 2026-11-23

### Added

- Buttons in the player bar to skip back or ahead 15 seconds.
- Each speaker's name in a transcript has its own color, so it's easier to see who's talking. You're in the accent color and unidentified voices are gray.

### Changed

- The play button is larger and sits in the middle of the player bar, and a muted track is marked in orange.
- Transcript lines no longer have a divider between them.

### Fixed

- The Summary tab's Previous Versions menu no longer closes by itself when you open it just as a summary finishes.

## [0.2.1] - 2026-11-19

### Fixed

- With Parakeet and a short vocabulary list, terms no longer appear in place of unrelated words. Use Transcribe Again on meetings transcribed before the fix.

## [0.2.0] - 2026-11-16

### Added

- A Settings button at the foot of the sidebar, so Settings opens from the main window as well as the app menu and the menu bar.

### Fixed

- The app in the DMG now passes `codesign --verify --strict`. Making the DMG added a Finder attribute that the strict check rejects, though macOS and updates accepted the app.

## [0.1.0] - 2026-11-15

The first release.

### Added

- Record your microphone and the audio your Mac plays as two tracks, with level meters, recovery after a crash, and a menu bar item and global shortcut to start and stop.
- Transcribe on your Mac with Apple's speech engine or Parakeet, with custom vocabulary.
- Tell speakers apart, name them, merge and reassign them, and optionally remember voices.
- Summaries from a built-in Gemma 4 model or an OpenAI-compatible server you choose, with editable templates.
- Notes during a meeting, tied to the moment you typed them, and an AI cleanup you review before accepting.
- Search across every meeting, chat about your meetings with answers that cite the moment they came from, and ask about a single meeting.
- Export a meeting as Markdown or plain text.
- A first-run guide, updates through Sparkle or Homebrew, and a signed, notarized DMG.

[Unreleased]: https://github.com/RossLopez/minutes/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/RossLopez/minutes/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/RossLopez/minutes/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/RossLopez/minutes/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/RossLopez/minutes/releases/tag/v0.1.0
