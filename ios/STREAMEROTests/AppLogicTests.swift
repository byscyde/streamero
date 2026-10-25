import StreameroCore
import SwiftUI
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

    func testTabsIncludeExploreAndNoCreateTab() {
        XCTAssertEqual(AppTab.allCases, [.home, .search, .explore, .library])
        XCTAssertEqual(AppTab.explore.title, "Explore")
        XCTAssertEqual(AppTab.library.title, "Library")
    }

    func testBrandingIdentifiers() {
        XCTAssertEqual(SyncCenter.backgroundTaskId, "com.scyde.streamero.sync")
        XCTAssertEqual(AppModel.keychainService, "com.streamero.session", "keychain service name stays stable")
        if let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] {
            XCTAssertTrue(permitted.contains(SyncCenter.backgroundTaskId))
        }
    }

    func testAppearanceStoreAppliesRemoteConfig() {
        let store = AppearanceStore(config: .defaults)
        XCTAssertEqual(store.config, AppConfig.defaults)
        var changed: AppConfig?
        store.onChange = { changed = $0 }
        var config = AppConfig.defaults
        config.version = "v2"
        config.theme.accent = "#0066FF"
        config.features.equalizer = false
        store.apply(config, persist: false)
        XCTAssertEqual(store.config.version, "v2")
        XCTAssertEqual(changed?.version, "v2")
        XCTAssertFalse(store.features.equalizer)
        XCTAssertEqual(UIColor(store.palette.accent).cgColor.components?.first ?? -1, 0, accuracy: 0.01)
        changed = nil
        store.apply(config, persist: false)
        XCTAssertNil(changed, "identical documents are not re-applied")
    }

    func testPaletteMixing() {
        XCTAssertEqual(ResolvedPalette.mix(0x000000, 0xFFFFFF, 0), 0x000000)
        XCTAssertEqual(ResolvedPalette.mix(0x000000, 0xFFFFFF, 1), 0xFFFFFF)
        XCTAssertEqual(ResolvedPalette.mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
    }

    func testSettingsDecodeWithoutNewFieldsKeepsValues() throws {
        // A settings file written by the previous version (no `equalizer` key) must still load.
        let old = #"{"crossfadeSeconds":6,"gapless":false,"appearance":"light"}"#
        let values = try JSONDecoder().decode(SettingsStore.Values.self, from: Data(old.utf8))
        XCTAssertEqual(values.crossfadeSeconds, 6)
        XCTAssertFalse(values.gapless)
        XCTAssertEqual(values.appearance, .light)
        XCTAssertEqual(values.equalizer, EqualizerSettings())
        var withEQ = values
        withEQ.equalizer.apply(.rock)
        let round = try JSONDecoder().decode(SettingsStore.Values.self, from: JSONEncoder().encode(withEQ))
        XCTAssertEqual(round, withEQ)
    }

    func testEqualizerParametersHandOffToRenderSide() {
        let params = EqualizerParameters()
        var settings = EqualizerSettings(enabled: true)
        settings.setGain(6, forBand: 5)
        params.update(settings, active: true)
        let gains = UnsafeMutablePointer<Double>.allocate(capacity: EqualizerDesign.bandCount)
        defer { gains.deallocate() }
        var preamp = 0.0
        var enabled = false
        let generation = params.tryCopy(ifNewerThan: 0, gains: gains, preamp: &preamp, enabled: &enabled)
        XCTAssertNotNil(generation)
        XCTAssertTrue(enabled)
        XCTAssertEqual(gains[5], 6)
        XCTAssertNil(params.tryCopy(ifNewerThan: generation!, gains: gains, preamp: &preamp, enabled: &enabled), "unchanged parameters are not copied again")
        params.update(settings, active: false) // remote feature switch off
        XCTAssertNotNil(params.tryCopy(ifNewerThan: generation!, gains: gains, preamp: &preamp, enabled: &enabled))
        XCTAssertFalse(enabled)
    }

    func testStableGenreGradientIndex() {
        XCTAssertEqual(Theme.Gradients.stableIndex("Pop", count: 10), Theme.Gradients.stableIndex("pop", count: 10))
        XCTAssertTrue((0..<10).contains(Theme.Gradients.stableIndex("Rock and Metal", count: 10)))
    }
}
