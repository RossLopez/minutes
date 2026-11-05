# Minutes

A free, open source, native macOS meeting recorder for Apple Silicon. Minutes records system audio and your microphone on separate tracks, then transcribes and summarizes the meeting on your Mac. Nothing leaves your Mac, there are no accounts, and it never joins your meetings as a bot.

**Status:** early development. The app doesn't record anything yet.

## Requirements

- macOS 27 or later on Apple Silicon
- Xcode 27 to build

## Build from source

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open Minutes.xcodeproj
```

Builds are ad-hoc signed by default, so you don't need an Apple account. To sign with your own identity, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and add your Team ID.

## License

Minutes is licensed under the [GNU General Public License, version 3 or later](LICENSE).
