import StreameroCore
import XCTest
@testable import STREAMERO

@MainActor
final class AppLogicTests: XCTestCase {
    func testServerIsFixedAndHttpsOnly() {
        XCTAssertEqual(ServerConfig.fallback.absoluteString, "https://app.streamero.net")
        XCTAssertEqual(ServerConfig.url.absoluteString, "https://app.streamero.net")
        XCTAssertEqual(ServerConfig.resolve(" https://staging.example.com ").absoluteString, "https://staging.example.com")
        XCTAssertEqual(ServerConfig.resolve("http://insecure.example.com"), ServerConfig.fallback)
        XCTAssertEqual(ServerConfig.resolve("$(STREAMERO_SERVER_URL)"), ServerConfig.fallback)
        XCTAssertEqual(ServerConfig.resolve(nil), ServerConfig.fallback)
    }

    func testArtworkVariantSelection() {
        let url = URL(string: "https://s.example/v1/artwork/abc")!
        XCTAssertEqual(artworkURL(url, points: 48)?.query, "size=small")
        XCTAssertEqual(artworkURL(url, points: 300)?.query, "size=large")
        XCTAssertNil(artworkURL(nil, points: 10))
    }

    func testQualityBadgeNeverClaimsLosslessForLossyDelivery() {
        let lossy = PlaybackQualityInfo(profile: .lossless, deliveredCodec: "aac", deliveredBitrateKbps: 256, deliveredLossless: false,
                                        source: SourceQuality(codec: "flac", lossless: true), isOffline: false)
        XCTAssertEqual(lossy.badge, "AAC 256")
        let lossless = PlaybackQualityInfo(profile: .lossless, deliveredCodec: "alac", deliveredBitrateKbps: nil, deliveredLossless: true, source: nil, isOffline: false)
        XCTAssertEqual(lossless.badge, "Lossless")
    }

    func testDeepLinks() {
        let model = AppModel()
        model.handle(url: URL(string: "streamero://verify-email?token=abc123")!)
        XCTAssertEqual(model.pendingDeepLink, .verifyEmail("abc123"))
        model.handle(url: URL(string: "streamero://reset-password?token=xyz")!)
        XCTAssertEqual(model.pendingDeepLink, .resetPassword("xyz"))
        model.pendingDeepLink = nil
        model.handle(url: URL(string: "https://evil.example/verify-email?token=1")!)
        XCTAssertNil(model.pendingDeepLink)
    }

    func testLibraryStoreOptimisticToggle() {
        let store = LibraryStore()
        store.reset()
        XCTAssertFalse(store.contains(.track, "t1"))
        store.toggle(.track, "t1")
        XCTAssertTrue(store.contains(.track, "t1"))
        store.toggle(.track, "t1")
        XCTAssertFalse(store.contains(.track, "t1"))
    }
}
