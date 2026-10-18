import XCTest

final class SmokeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testFreshLaunchShowsServerOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        let field = app.textFields["serverAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Onboarding asks for the server address")
        XCTAssertTrue(app.staticTexts["STREAMERO"].exists || app.otherElements["STREAMERO"].exists)
        field.tap()
        field.typeText("not a url")
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.staticTexts["Enter a valid address"].waitForExistence(timeout: 5) || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'reach'")).firstMatch.waitForExistence(timeout: 10))
    }
}
