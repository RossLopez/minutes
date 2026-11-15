// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

#if DEBUG
    /// Sets the appearance and the main window's size for ScreenshotUITests, whatever this Mac is set
    /// to. On macOS 27 an `-AppleInterfaceStyle` launch argument doesn't change the appearance, and a
    /// `-NSWindow Frame main` one doesn't change the restored size. Debug builds only.
    @MainActor
    enum ScreenshotMode {
        private static var observers: [any NSObjectProtocol] = []

        static func apply(environment: [String: String] = ProcessInfo.processInfo.environment) {
            switch environment["MINUTES_APPEARANCE"] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
            let size = environment["MINUTES_WINDOW_SIZE"].map(NSSizeFromString) ?? .zero
            guard size.width > 0, size.height > 0 else {
                return
            }
            NSApp.windows.forEach { resize($0, to: size) }
            // SwiftUI restores the saved frame after launch, which resizes it again.
            observers = [NSWindow.didBecomeMainNotification, NSWindow.didResizeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                    let window = notification.object as? NSWindow
                    MainActor.assumeIsolated {
                        window.map { resize($0, to: size) }
                    }
                }
            }
        }

        private static func resize(_ window: NSWindow, to size: NSSize) {
            guard window.identifier?.rawValue == SceneID.mainWindow, window.frame.size != size else {
                return
            }
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            window.center()
        }
    }
#endif
