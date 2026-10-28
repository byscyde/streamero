import XCTest

final class SmokeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// A fresh install opens the set-up sheet with every service prefilled; adding a key opens the editor.
    @MainActor
    func testFirstLaunchShowsServiceSetup() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Set up"].waitForExistence(timeout: 10))
        for name in ["Jellyfin", "Sonarr", "Radarr", "Prowlarr", "Bazarr"] {
            XCTAssertTrue(app.staticTexts[name].exists, "\(name) is listed")
        }
        app.staticTexts["Sonarr"].tap()
        XCTAssertTrue(app.secureTextFields["apiKeyField"].waitForExistence(timeout: 5))
        let url = app.textFields["serviceURLField"]
        XCTAssertTrue(url.exists)
        XCTAssertEqual(url.value as? String, "https://son.streamero.net")
    }
}
