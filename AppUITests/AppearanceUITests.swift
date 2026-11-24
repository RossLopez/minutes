// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import XCTest

/// Settings › General › Appearance keeps the app light or dark whatever the Mac is set to. Each case
/// sets the opposite of the other, so one of them differs from this Mac's appearance.
final class AppearanceUITests: MinutesUITestCase {
    @MainActor
    func testDarkAppearanceWins() {
        check(.dark)
    }

    @MainActor
    func testLightAppearanceWins() {
        check(.light)
    }

    private enum Expected: String {
        case light
        case dark
    }

    @MainActor
    private func check(_ expected: Expected) {
        launch(arguments: ["-general.appearance", expected.rawValue, "-settings.selectedTab", "general"])
        let gear = app.buttons["sidebarSettings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        assertLooks(expected, app.windows.containing(.button, identifier: "sidebarSettings").firstMatch,
                    "the main window")

        gear.click()
        let picker = app.popUpButtons["appearance"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.value as? String, expected == .dark ? "Dark" : "Light")
        assertLooks(expected, app.windows.containing(.popUpButton, identifier: "appearance").firstMatch, "Settings")
    }

    /// Light windows are mostly near white and dark ones near black, so the average brightness tells
    /// them apart without depending on what's in the window.
    @MainActor
    private func assertLooks(_ expected: Expected, _ window: XCUIElement, _ name: String) {
        let brightness = averageBrightness(window.screenshot().image)
        switch expected {
        case .dark: XCTAssertLessThan(brightness, 0.4, "\(name) should be dark")
        case .light: XCTAssertGreaterThan(brightness, 0.6, "\(name) should be light")
        }
    }

    private func averageBrightness(_ image: NSImage) -> Double {
        let side = 16
        // Drawn into a small grayscale bitmap, which averages the pixels as it scales.
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        XCTAssertTrue(drawn, "Couldn't read the screenshot")
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count * 255)
    }
}
