// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon.HIToolbox

/// A key combination for the global shortcut, stored in `UserDefaults`.
struct HotKeyShortcut: Codable, Equatable {
    static let `default` = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(cmdKey | optionKey),
        display: "⌥⌘R",
    )

    private static let storageKey = "globalShortcut"

    let keyCode: UInt32
    /// Carbon modifier flags.
    let modifiers: UInt32
    let display: String

    static func load() -> HotKeyShortcut {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
        else {
            return .default
        }
        return shortcut
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// A shortcut from a key press, or nil if it has no modifier that makes it safe to take globally.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .control, .option]) else {
            return nil
        }
        var modifiers = 0
        var symbols = ""
        if flags.contains(.control) {
            modifiers |= controlKey
            symbols += "⌃"
        }
        if flags.contains(.option) {
            modifiers |= optionKey
            symbols += "⌥"
        }
        if flags.contains(.shift) {
            modifiers |= shiftKey
            symbols += "⇧"
        }
        if flags.contains(.command) {
            modifiers |= cmdKey
            symbols += "⌘"
        }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        keyCode = UInt32(event.keyCode)
        self.modifiers = UInt32(modifiers)
        display = symbols + (key.isEmpty ? "Key \(event.keyCode)" : key)
    }

    private init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }
}

/// Starts and stops recording from any app. Carbon's hot key API is still the supported way to
/// do this without an Accessibility permission, and it needs no third-party package.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var onPress: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    /// Returns false if the combination can't be registered, usually because another app has it.
    @discardableResult
    func register(_ shortcut: HotKeyShortcut) -> Bool {
        installHandlerIfNeeded()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x4D4E_5453), id: 1) // "MNTS"
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference,
        )
        guard status == noErr else {
            return false
        }
        hotKeyRef = reference
        return true
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            return
        }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                // The application event target delivers on the main thread.
                MainActor.assumeIsolated {
                    GlobalHotKey.shared.onPress?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef,
        )
    }
}
