// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Adding an OpenAI-compatible server in Settings, testing it, picking its model for summaries,
/// and a recording summarized by it.
final class EndpointFlowUITests: MinutesUITestCase {
    private var server: StubLLMServer!

    override func tearDownWithError() throws {
        server?.stop()
        try super.tearDownWithError()
    }

    @MainActor
    func testAddServerAndSummarizeWithIt() throws {
        server = try StubLLMServer()
        let port = try server.start()
        launch(tab: "summary")
        XCTAssertTrue(record.waitForExistence(timeout: 10))

        // Add the server in Settings and test it.
        app.typeKey(",", modifierFlags: .command)
        let modelsTab = app.toolbars.buttons["AI Models"]
        XCTAssertTrue(modelsTab.waitForExistence(timeout: 10))
        modelsTab.click()
        app.buttons["addEndpoint"].click()
        let name = app.textFields["endpointName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Stub")
        let address = app.textFields["endpointURL"]
        address.click()
        // Without its /v1, which Test Connection adds.
        address.typeText("http://127.0.0.1:\(port)")
        app.buttons["endpointTest"].click()
        XCTAssertTrue(app.staticTexts["Connected · 1 model"].waitForExistence(timeout: 10))
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:\(port)/v1")
        XCTAssertFalse(app.descendants(matching: .any)["endpointRemoteWarning"].exists)
        app.buttons["endpointSave"].click()
        let row = app.descendants(matching: .any)["endpoint-Stub"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // Pick its model for summaries.
        let summaries = app.popUpButtons["model-summaries"]
        summaries.click()
        app.menuItems[StubLLMServer.model].click()
        wait(for: "model chosen") { (summaries.value as? String)?.contains(StubLLMServer.model) == true }
        app.typeKey("w", modifierFlags: .command)

        // A recording is summarized by the server, and says so.
        record.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        stop.click()
        let summary = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Written by the stub server"))
        XCTAssertTrue(summary.firstMatch.waitForExistence(timeout: 30))
        let label = app.descendants(matching: .any)["summaryModel"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertTrue(label.label.hasPrefix("Written by \(StubLLMServer.model) on Stub,"), label.label)

        // The transcript went to the server, and the summary was saved with the endpoint's model.
        XCTAssertTrue(server.chatRequests.last?.contains("agree the budget before Friday") == true)
        let folder = try XCTUnwrap(folders(in: meetings).first)
        let saved = try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        XCTAssertTrue(saved.contains("Check the stub."))
        app.terminate()
    }
}
