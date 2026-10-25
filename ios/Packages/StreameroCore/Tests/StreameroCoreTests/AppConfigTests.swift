import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StreameroCore

final class AppConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder.streamero.decode(AppConfig.self, from: Data(json.utf8))
    }

    func testDecodesDocumentedSampleAndMatchesDefaults() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "app_config", withExtension: "json", subdirectory: "Fixtures"))
        let config = try JSONDecoder.streamero.decode(AppConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(config.version, "3f9a1c0b2d4e5f60")
        var expected = AppConfig.defaults
        expected.version = "3f9a1c0b2d4e5f60"
        XCTAssertEqual(config, expected, "the documented sample is exactly the default document")
    }

    func testDefaultsMatchDocumentation() {
        let d = AppConfig.defaults
        XCTAssertEqual(d.brand.appName, "STREAMERO")
        XCTAssertEqual(d.brand.developer, "SCYDE")
        XCTAssertEqual(d.brand.developerUrl, "https://scyde.dev")
        XCTAssertEqual(d.theme.accent, "#E31E2D")
        XCTAssertEqual(d.theme.background, "#0E0E10")
        XCTAssertEqual(d.theme.titleFont, .mono)
        XCTAssertEqual(d.theme.cornerRadius, 12)
        XCTAssertEqual(d.theme.playerStyle, .artwork)
        XCTAssertEqual(d.home.chips, ["All", "Music", "Videos"])
        XCTAssertEqual(d.home.sectionsOrder.first, "recommended_playlists")
        XCTAssertEqual(d.home.sectionsOrder.count, 8)
        XCTAssertTrue(d.features.equalizer && d.features.signup && d.features.appleSignIn && d.features.videos)
        XCTAssertFalse(d.announcement.enabled)
        XCTAssertFalse(d.announcement.isVisible)
        XCTAssertTrue(d.texts.homeGreeting)
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let c = try decode(##"{"version":"v2","theme":{"accent":"#00AAFF","cornerRadius":40},"features":{"videos":false},"announcement":{"enabled":true,"text":"Maintenance tonight","style":"warning"}}"##)
        XCTAssertEqual(c.version, "v2")
        XCTAssertEqual(c.theme.accent, "#00AAFF")
        XCTAssertEqual(c.theme.background, AppConfig.defaults.theme.background)
        XCTAssertEqual(c.theme.cornerRadius, 28, "corner radius is clamped to 0…28")
        XCTAssertFalse(c.features.videos)
        XCTAssertTrue(c.features.youtube)
        XCTAssertEqual(c.brand, AppConfig.defaults.brand)
        XCTAssertEqual(c.home, AppConfig.defaults.home)
        XCTAssertTrue(c.announcement.isVisible)
        XCTAssertEqual(c.announcement.style, .warning)
        XCTAssertEqual(c.visibleHomeChips, ["All", "Music"], "Videos chip disappears with the videos feature")

        let empty = try decode("{}")
        XCTAssertEqual(empty, AppConfig.defaults)
    }

    func testMalformedValuesAreIgnored() throws {
        let c = try decode(#"{"theme":{"accent":"red","titleFont":"comic","playerStyle":42,"genreGradients":"yes"},"home":{"chips":["Videos","Bogus","All","All"]}}"#)
        XCTAssertEqual(c.theme.accent, "#E31E2D")
        XCTAssertEqual(c.theme.titleFont, .mono)
        XCTAssertEqual(c.theme.playerStyle, .artwork)
        XCTAssertTrue(c.theme.genreGradients)
        XCTAssertEqual(c.visibleHomeChips, ["Videos", "All"])
    }

    func testRoundTripsThroughCache() throws {
        var c = AppConfig.defaults
        c.version = "abc"
        c.theme.titleFont = .rounded
        let data = try JSONEncoder.streamero.encode(c)
        XCTAssertEqual(try JSONDecoder.streamero.decode(AppConfig.self, from: data), c)
    }

    func testHexColourParsing() {
        XCTAssertEqual(HexColor("#E31E2D")?.rgb, 0xE31E2D)
        XCTAssertEqual(HexColor("e31e2d")?.rgb, 0xE31E2D)
        XCTAssertEqual(HexColor(" #fff ")?.rgb, 0xFFFFFF)
        XCTAssertNil(HexColor("#12345"))
        XCTAssertNil(HexColor("#GGGGGG"))
        XCTAssertNil(HexColor(""))
        let red = HexColor("#FF0000")!
        XCTAssertEqual(red.red, 1, accuracy: 1e-9)
        XCTAssertEqual(red.green, 0, accuracy: 1e-9)
        XCTAssertEqual(HexColor(rgb: 0x0A0B0C).hexString, "#0A0B0C")
        XCTAssertGreaterThan(HexColor("#FFFFFF")!.luminance, HexColor("#0E0E10")!.luminance)
    }

    func testRefetchDecision() {
        XCTAssertTrue(AppConfig.needsRefetch(cachedVersion: nil, serverVersion: "a"))
        XCTAssertTrue(AppConfig.needsRefetch(cachedVersion: "a", serverVersion: "b"))
        XCTAssertFalse(AppConfig.needsRefetch(cachedVersion: "a", serverVersion: "a"))
        XCTAssertFalse(AppConfig.needsRefetch(cachedVersion: "a", serverVersion: nil), "older servers without configVersion")
    }

    func testSyncStateConfigVersionIsOptional() throws {
        let old = try JSONDecoder.streamero.decode(SyncState.self, from: Data(#"{"catalogVersion":"c","libraryVersion":"l","serverTime":"2026-01-01T00:00:00.000Z"}"#.utf8))
        XCTAssertNil(old.configVersion)
        let new = try JSONDecoder.streamero.decode(SyncState.self, from: Data(#"{"catalogVersion":"c","libraryVersion":"l","serverTime":"2026-01-01T00:00:00.000Z","configVersion":"v9"}"#.utf8))
        XCTAssertEqual(new.configVersion, "v9")
    }

    func testAppConfigEndpointNeedsNoAuth() async throws {
        let transport = MockTransport { req, _ in
            XCTAssertEqual(req.url?.path, "/v1/app/config")
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
            return (200, #"{"version":"x1","brand":{"appName":"STREAMERO"}}"#)
        }
        let api = APIClient(baseURL: URL(string: "https://api.example.test")!, tokenStore: InMemoryTokenStore(), transport: transport)
        let config = try await api.appConfig()
        XCTAssertEqual(config.version, "x1")
        XCTAssertEqual(config.theme, AppConfig.defaults.theme)
    }

    func testHomeSectionOrdering() {
        let kinds = ["recently_played", "made_for_you", "favorite_artists", "recently_added", "trending", "genres", "featured_playlists", "something_new"]
        let order = HomeSectionOrdering.order(kinds: kinds, by: AppConfig.defaults.home.sectionsOrder)
        XCTAssertEqual(order.map { kinds[$0] }, ["featured_playlists", "genres", "favorite_artists", "recently_added", "trending", "recently_played", "made_for_you", "something_new"])
        let custom = HomeSectionOrdering.order(kinds: kinds, by: ["made_for_you"], hidden: ["genres"])
        XCTAssertEqual(kinds[custom[0]], "made_for_you")
        XCTAssertFalse(custom.map { kinds[$0] }.contains("genres"))
        XCTAssertEqual(custom.count, kinds.count - 1)
        XCTAssertEqual(HomeSectionOrdering.configId(forKind: "continue_watching"), "music_videos")
        XCTAssertNil(HomeSectionOrdering.configId(forKind: "editorial_x"))
    }
}
