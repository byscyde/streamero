import XCTest

final class SmokeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// A fresh install goes straight to the welcome screen: no server address is ever asked for.
    @MainActor
    func testFreshLaunchShowsWelcomeWithoutServerEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        let signUp = app.buttons["signUpButton"]
        XCTAssertTrue(signUp.waitForExistence(timeout: 10), "Welcome screen is shown")
        XCTAssertFalse(app.textFields["serverAddressField"].exists, "Users never type a server address")
        XCTAssertTrue(app.textFields["welcomeEmailField"].exists, "Welcome screen offers sign-up with email")
        app.buttons["logInButton"].tap()
        let email = app.textFields["emailField"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["authSubmit"].isEnabled, "Log in stays disabled until email and password are entered")
        email.tap()
        email.typeText("listener@example.com")
        let password = app.secureTextFields["passwordField"]
        password.tap()
        password.typeText("password123")
        XCTAssertTrue(app.buttons["authSubmit"].isEnabled)
        XCTAssertTrue(app.buttons["forgotPasswordButton"].exists, "Forgot password? is offered on the login screen")
    }
}
