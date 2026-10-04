import XCTest
final class MobileProductTests:XCTestCase {
    @MainActor func testProductEntryAndNavigation() async throws {
        let app=XCUIApplication()
        app.launchEnvironment=["CHATTERBOX_TEST_HOST":"127.0.0.1","CHATTERBOX_TEST_CODE":"123456","CHATTERBOX_TEST_PORT":"47411"]
        #if GOLEM_APP && GOLEM_CROSS_APP_TEST
        let chatterbox=XCUIApplication(bundleIdentifier:"com.shelbyklein.Chatterbox.mobile")
        chatterbox.launchEnvironment=app.launchEnvironment
        chatterbox.launch()
        XCTAssertTrue(chatterbox.buttons["chat-33333333-3333-3333-3333-333333333333"].waitForExistence(timeout:15))
        #endif
        app.launch()
        #if GOLEM_APP
        XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Journal")).firstMatch.waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["Fixture briefing"].waitForExistence(timeout:10))
        capture("golem-conversation",app)
        XCUIDevice.shared.orientation = .landscapeLeft
        try await Task.sleep(for:.seconds(2))
        XCTAssertTrue(app.buttons["Message Golem"].exists)
        capture("golem-landscape",app)
        XCUIDevice.shared.orientation = .portrait
        app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Journal")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Fixture journal entry"].waitForExistence(timeout:10))
        capture("golem-journal",app)
        #if GOLEM_CROSS_APP_TEST
        app.buttons["Open in Chatterbox"].tap()
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout:3),springboard.alerts.buttons["Open"].exists{springboard.alerts.buttons["Open"].tap()}
        XCTAssertTrue(chatterbox.wait(for:.runningForeground,timeout:10))
        XCTAssertTrue(chatterbox.staticTexts["Fixture ordinary reply"].waitForExistence(timeout:8))
        capture("golem-linked-chatterbox",chatterbox)
        app.activate()
        #endif
        XCTAssertTrue(app.staticTexts["Journal"].waitForExistence(timeout:5))
        app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Settings")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Disconnect Golem"].waitForExistence(timeout:5))
        for _ in 0..<4 {if app.buttons["Pause Automation"].isHittable{break};app.swipeUp()}
        XCTAssertTrue(app.buttons["Pause Automation"].waitForExistence(timeout:5))
        app.buttons["Pause Automation"].tap()
        XCTAssertTrue(app.buttons["Resume Automation"].waitForExistence(timeout:5))
        app.buttons["Resume Automation"].tap()
        XCTAssertTrue(app.buttons["Pause Automation"].waitForExistence(timeout:5))
        capture("golem-settings",app)
        app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Golem")).firstMatch.tap()
        try await connectivity(false)
        XCTAssertTrue(app.staticTexts["Can’t reach Golem on your Mac."].waitForExistence(timeout:10))
        capture("golem-offline",app)
        try await connectivity(true)
        for _ in 0..<20 {
            if !app.staticTexts["Can’t reach Golem on your Mac."].exists{break}
            try await Task.sleep(for:.milliseconds(500))
        }
        XCTAssertFalse(app.staticTexts["Can’t reach Golem on your Mac."].exists)
        capture("golem-reconnected",app)
        XCTAssertFalse(app.tabBars.buttons["Chats"].exists)
        #else
        let row=app.buttons["chat-33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(row.waitForExistence(timeout:15))
        XCTAssertFalse(app.buttons["chat-11111111-1111-1111-1111-111111111111"].exists)
        XCTAssertFalse(app.tabBars.buttons["Golem"].exists)
        capture("chatterbox-chats",app)
        row.tap()
        XCTAssertTrue(app.staticTexts["Fixture ordinary reply"].waitForExistence(timeout:8))
        XCTAssertTrue(app.buttons["Send"].exists)
        capture("chatterbox-conversation",app)
        #endif
    }
    @MainActor func testLargeText() throws {
        let app=XCUIApplication()
        app.launchArguments=["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment=["CHATTERBOX_TEST_HOST":"127.0.0.1","CHATTERBOX_TEST_CODE":"123456","CHATTERBOX_TEST_PORT":"47411"]
        app.launch()
        #if GOLEM_APP
        XCTAssertTrue(app.buttons["Message Golem"].waitForExistence(timeout:15))
        #else
        XCTAssertTrue(app.buttons["chat-33333333-3333-3333-3333-333333333333"].waitForExistence(timeout:15))
        #endif
        capture("large-text",app)
    }
    func connectivity(_ online:Bool) async throws {
        var request=URLRequest(url:URL(string:"http://127.0.0.1:47411/test/offline")!)
        request.httpMethod="POST";request.httpBody=try JSONSerialization.data(withJSONObject:["offline":!online])
        _ = try await URLSession.shared.data(for:request)
    }
    @MainActor func capture(_ name:String,_ app:XCUIApplication){let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)}
}
