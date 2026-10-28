import StreameroKit
import XCTest
@testable import STREAMERO

@MainActor
final class AppTests: XCTestCase {
    func testFirstLaunchListsEveryServiceWithStreameroAddresses() {
        Keychain.save(nil, service: AppState.keychainService)
        let state = AppState()
        XCTAssertEqual(Set(state.services.map(\.kind)), Set(ServiceKind.allCases))
        XCTAssertEqual(state.services.first { $0.kind == .jellyfin }?.url, "https://streamero.net")
        XCTAssertFalse(state.hasAnyConfigured, "nothing works until API keys are entered")
    }

    func testServicesPersistInKeychain() {
        Keychain.save(nil, service: AppState.keychainService)
        let state = AppState()
        var sonarr = state.services.first { $0.kind == .sonarr }!
        sonarr.apiKey = "secret-key"
        state.upsert(sonarr)
        let reloaded = AppState()
        XCTAssertEqual(reloaded.first(.sonarr)?.apiKey, "secret-key")
        XCTAssertNoThrow(try reloaded.sonarr(reloaded.first(.sonarr)!))
        Keychain.save(nil, service: AppState.keychainService)
    }

    func testClientsUseTheConfiguredAddress() throws {
        let state = AppState()
        let instance = ServiceInstance(kind: .radarr, url: "rad.streamero.net", apiKey: "k")
        let request = try state.client(instance).request(.get, "movie")
        XCTAssertEqual(request.url?.absoluteString, "https://rad.streamero.net/api/v3/movie")
    }
}
