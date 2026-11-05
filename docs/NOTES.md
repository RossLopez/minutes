# Engineering notes

Spec-level decisions, and places where Apple APIs behave differently than documented.

## Decisions

### Minimum OS is macOS 27 (Nov 5, 2026)

The spec originally targeted macOS 26. Ross chose to support only macOS 27, the latest release, and `docs/BUILD_PROMPT.md` was updated to match.

- The package manifest uses `.macOS(.v27)`, which needs `swift-tools-version: 6.4`.
- CI runs on the `xcode-27` image, which runs macOS 27. The `macos-26` and `macos-latest` images are still on macOS 26.
- The Homebrew cask will use `depends_on macos: ">= :golden_gate"`.

## Apple API notes

### `MenuBarExtra`'s title doesn't reach VoiceOver (Nov 5, 2026)

On macOS 27, `MenuBarExtra("Minutes", systemImage: "waveform")` exposes the status item to accessibility as "Audio Waveform", the symbol's name, instead of the title. The workaround is the `label:` initializer with `Image(systemName:).accessibilityLabel("Minutes")`, confirmed through the item's `AXTitle`.

### `NSAudioCaptureUsageDescription` belongs in a real Info.plist (Nov 5, 2026)

Third-party reports say Xcode's `INFOPLIST_KEY_*` build settings silently drop this key. This is untested here. To avoid the risk, the app uses a hand-written `App/Info.plist`, and `scripts/verify-bundle.sh` checks the key in the built bundle.
