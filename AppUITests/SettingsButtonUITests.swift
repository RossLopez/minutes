// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The gear at the foot of the sidebar opens Settings, without the app menu or the menu bar.
final class SettingsButtonUITests: MinutesUITestCase {
    @MainActor
    func testSidebarButtonOpensSettings() {
        // Pinned so the window opens on General, whichever tab this Mac's Settings was last left on.
        launch(arguments: ["-settings.selectedTab", "general"])
        let gear = app.buttons["sidebarSettings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        XCTAssertEqual(gear.label, "Settings", "VoiceOver reads the button's name, not the symbol's")
        XCTAssertEqual(app.windows.count, 1)

        gear.click()
        XCTAssertTrue(app.toolbars.buttons["General"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.toolbars.buttons["AI Models"].exists)
        XCTAssertEqual(app.windows.count, 2, "Settings opens in its own window")

        // Clicking again brings the same window forward rather than opening another.
        app.typeKey("`", modifierFlags: .command)
        gear.click()
        XCTAssertEqual(app.windows.count, 2)
    }
}
