import XCTest

@MainActor
final class SiriRoutingUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.freo.personal.control")
    private var pendingPhrase: String?
    private var expectedReply: String?
    private var previousReply = ""
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--freo-siri-routing-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["siriRoutingTestMode"].waitForExistence(timeout: 20),
                      "Do not invoke Siri unless the robot-start interceptor is active")
    }
    override func tearDownWithError() throws {
        // SiriService aborts the test method after its legacy UI timeout.
        // Verify here so an expected framework failure can never create a false pass.
        if let expectedReply {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = pendingPhrase ?? "Siri result"; shot.lifetime = .keepAlways; add(shot)
            let siri = XCUIApplication(bundleIdentifier: "com.apple.campo")
            let tree = XCTAttachment(string: siri.debugDescription)
            tree.name = "Actual Siri AI response"; tree.lifetime = .keepAlways; add(tree)
            XCUIDevice.shared.press(.home)
            app.activate()
            let result = app.staticTexts["siriRoutingTestResult"]
            let predicate = NSPredicate(format: "label CONTAINS %@ AND label != %@", expectedReply, previousReply)
            let matched = XCTNSPredicateExpectation(predicate: predicate, object: result)
            XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 15), .completed,
                           "No actual app result for " + (pendingPhrase ?? "Siri command"))
        }
        app.activate()
    }
    @discardableResult
    private func grantRequestedSiriAccess(_ siri: XCUIApplication) -> Bool {
        let prompt = siri.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "shortcuts with Siri")).firstMatch
        let turnOn = siri.buttons["Turn On"]
        guard prompt.exists, prompt.label.contains("Narwal") || prompt.label.contains("Freo Probe"), turnOn.exists else { return false }
        if !turnOn.isHittable {
            // Dismiss/scroll past the composer; never tap through an occluding view.
            let start = siri.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))
            let end = siri.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.75))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        let composer = siri.textFields["promptViewTextField"]
        guard turnOn.isHittable || (composer.exists && turnOn.frame.maxY + 8 < composer.frame.minY) else { return false }
        // Remote Shortcuts cards can report non-hittable despite a visible,
        // unobstructed button. Use its verified on-screen center in that case.
        turnOn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }
    func testGrantRequestedSiriAccess() {
        let siri = XCUIApplication(bundleIdentifier: "com.apple.campo")
        siri.activate()
        XCTAssertTrue(grantRequestedSiriAccess(siri), "Expected only our app's pending Siri permission")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Own-app Siri permission result"; shot.lifetime = .keepAlways; add(shot)
    }
    func invoke(_ phrase: String, expecting expected: String) {
        app.activate()
        let result = app.staticTexts["siriRoutingTestResult"]
        previousReply = result.exists ? result.label : ""
        pendingPhrase = phrase; expectedReply = expected
        let siri = XCUIApplication(bundleIdentifier: "com.apple.campo")
        siri.terminate()
        siri.launch()
        let conversations = siri.buttons["Conversations"]
        if conversations.isHittable { conversations.tap() }
        let newChat = siri.buttons["newChatButton"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        let field = siri.textFields["promptViewTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(phrase)
        siri.buttons["sendButton"].tap()
        var handledPermission = false
        let ready = NSPredicate { _, _ in
            if self.app.state == .runningForeground { return true }
            if !handledPermission { handledPermission = self.grantRequestedSiriAccess(siri) }
            return false
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30)

    }
    func testFailingLivingRoomCombinedCommand() {
        invoke("Run Narwal vacuum and mop Living room", expecting: "Vacuum & mop in Living room.")
    }
    func testSuffixPhrase() {
        invoke("Vacuum and mop Living room with Narwal", expecting: "Vacuum & mop in Living room.")
    }
    func testUseAppPhrase() {
        invoke("Use Narwal to vacuum and mop Laundry Room", expecting: "Vacuum & mop in Laundry Room.")
    }
    func testExplicitRobotPhrase() {
        invoke("Run Narwal robot vacuum and mop Laundry Room", expecting: "Vacuum & mop in Laundry Room.")
    }
    func testUniqueAppName() {
        invoke("Run Freo Probe vacuum and mop Laundry Room", expecting: "Vacuum & mop in Laundry Room.")
    }
    func testInspectActualSiriUI() {
        let siri = XCUIApplication(bundleIdentifier: "com.apple.campo")
        siri.activate()
        print("ACTUAL SIRI TREE BEFORE\n" + siri.debugDescription + "\nEND ACTUAL SIRI TREE")
        let ownPermission = siri.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Narwal", "shortcuts")).firstMatch
        let turnOn = siri.buttons["Turn On"]
        if ownPermission.exists && turnOn.isHittable { turnOn.tap() }
        print("ACTUAL SIRI TREE AFTER\n" + siri.debugDescription + "\nEND ACTUAL SIRI TREE")
    }
    func testInspectSiriConversationControls() {
        let siri = XCUIApplication(bundleIdentifier: "com.apple.campo")
        siri.activate()
        let conversations = siri.buttons["Conversations"]
        if conversations.isHittable { conversations.tap() }
        print("SIRI NAVIGATION\n" + siri.navigationBars.firstMatch.debugDescription)
        print("SIRI CREATE CONTROLS\n" + siri.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'new' OR identifier CONTAINS[c] 'compose' OR label CONTAINS[c] 'new'")).debugDescription)
    }
    func testTextRoomProbe() {
        invoke("Run Freo Probe text vacuum and mop Laundry Room", expecting: "Vacuum & mop in Laundry Room.")
    }
    func testModeOnlyRegistration() {
        app.activate()
        continueAfterFailure = true
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Run Narwal vacuum and mop")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Mode-only routing"; shot.lifetime = .keepAlways; add(shot)
    }
    func testInspectShortcutsCatalog() {
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()
        let library = shortcuts.buttons["Library"]
        if library.waitForExistence(timeout: 2) { library.tap() }
        let list = shortcuts.collectionViews["library.sidebar"]
        for _ in 0..<5 {
            if shortcuts.buttons["Narwal"].firstMatch.isHittable { break }
            if list.exists { list.swipeUp() }
        }
        let narwal = shortcuts.buttons["Narwal"].firstMatch
        if narwal.isHittable { narwal.tap() }
        print("SHORTCUTS TREE START\n" + shortcuts.debugDescription + "\nSHORTCUTS TREE END")
    }
    func testPublishedVacuumLaundryRoomTile() {
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()
        let ownCatalog = shortcuts.otherElements["com.freo.personal.control_auto_shortcuts"]
        if !ownCatalog.exists {
            let library = shortcuts.buttons["Library"]
            if library.waitForExistence(timeout: 2) { library.tap() }
            let list = shortcuts.collectionViews["library.sidebar"]
            for _ in 0..<5 {
                if shortcuts.buttons["Narwal"].firstMatch.isHittable { break }
                if list.exists { list.swipeUp() }
            }
            let narwal = shortcuts.buttons["Narwal"].firstMatch
            XCTAssertTrue(narwal.isHittable)
            narwal.tap()
        }
        XCTAssertTrue(ownCatalog.waitForExistence(timeout: 5),
                      "Never run a tile unless its catalog belongs to our intercepted app")
        let tile = ownCatalog.otherElements["Laundry Room"].buttons.firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        let hosts = [app, shortcuts, XCUIApplication(bundleIdentifier: "com.apple.springboard")]
        let predicate = NSPredicate { _, _ in
            hosts.contains { host in
                host.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Vacuum in Laundry Room.")).firstMatch.exists
            }
        }
        let matched = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 20), .completed)
    }
}
