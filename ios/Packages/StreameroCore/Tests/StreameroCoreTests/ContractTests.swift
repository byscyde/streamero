import Foundation
import XCTest
@testable import StreameroCore

/// Decodes JSON captured from the real backend, so model drift between server and app fails CI.
final class ContractTests: XCTestCase {
    func fixture<T: Decodable>(_ name: String, as: T.Type = T.self) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder.streamero.decode(T.self, from: Data(contentsOf: url))
    }

    func testSessionAndUser() throws {
        let s: Session = try fixture("session")
        XCTAssertEqual(s.tokenType, "Bearer")
        XCTAssertEqual(s.user.role, "admin")
        let me: User = try fixture("me")
        XCTAssertEqual(me.email, "admin@streamero.local")
        XCTAssertNotNil(me.preferencesVersion)
    }

    func testCatalogPages() throws {
        let t: Track = try fixture("track")
        XCTAssertEqual(t.title, "Smoke Test")
        XCTAssertEqual(t.sourceQuality?.lossless, true)
        XCTAssertTrue(t.supportsLossless)
        XCTAssertTrue(t.isLiked)
        let album: AlbumPage = try fixture("album")
        XCTAssertEqual(album.tracks.first?.id, t.id)
        let artist: ArtistPage = try fixture("artist")
        XCTAssertEqual(artist.artist.name, "Worker")
        let liked: Page<Track> = try fixture("liked")
        XCTAssertEqual(liked.total, 1)
    }

    func testHomeFeedHeterogeneousItems() throws {
        let home: HomeFeed = try fixture("home")
        XCTAssertFalse(home.isCatalogEmpty)
        XCTAssertTrue(home.greeting.hasPrefix("Good"))
        let items = home.sections.flatMap(\.items)
        XCTAssertFalse(items.isEmpty)
        XCTAssertFalse(items.contains { if case .unknown = $0 { return true }; return false })
        XCTAssertTrue(items.contains { if case .track = $0 { return true }; return false })
    }

    func testStreamsAndVideo() throws {
        let s: TrackStream = try fixture("stream")
        XCTAssertEqual(s.profile, "lossless")
        XCTAssertTrue(s.delivery.lossless)
        XCTAssertEqual(s.delivery.codec, "alac")
        XCTAssertGreaterThan(s.expiresAt, Date(timeIntervalSince1970: 1_700_000_000))
        let v: VideoPage = try fixture("video")
        XCTAssertEqual(v.video.subtitles.first?.language, "en")
        XCTAssertEqual(v.video.progress?.positionMs, 1500)
        let vs: VideoStream = try fixture("video_stream")
        XCTAssertTrue(vs.hlsUrl.absoluteString.hasSuffix("/master.m3u8"))
        XCTAssertEqual(vs.qualities.first?.height, 360)
        XCTAssertNotNil(vs.audioOnly)
        XCTAssertNotNil(vs.timelinePreview)
        let videos: Page<Video> = try fixture("videos")
        XCTAssertEqual(videos.items.count, 1)
    }

    func testSearchPlaylistMixesAndErrors() throws {
        let search: SearchResponse = try fixture("search")
        XCTAssertEqual(search.results.tracks?.items.first?.title, "Smoke Test")
        XCTAssertFalse(search.results.isEmpty)
        let pl: PlaylistPage = try fixture("playlist")
        XCTAssertEqual(pl.playlist.itemCount, 1)
        XCTAssertNotNil(pl.playlist.shareUrl)
        XCTAssertNotNil(pl.items.items.first?.track)
        let mixes: ItemsResponse<Mix> = try fixture("mixes")
        XCTAssertFalse(mixes.items.isEmpty)
        let err: ErrorEnvelope = try fixture("error")
        XCTAssertEqual(err.error.code, "invalid_token")
    }

    func testDateFormats() {
        XCTAssertNotNil(StreameroDate.parse("2026-10-18T19:42:55.804Z"))
        XCTAssertNotNil(StreameroDate.parse("2026-10-18T19:42:55.804441+00:00"))
        XCTAssertNotNil(StreameroDate.parse("2026-10-18T19:42:55Z"))
        XCTAssertNotNil(StreameroDate.parse("2024-02-02"))
        XCTAssertNil(StreameroDate.parse("yesterday"))
        let a = StreameroDate.parse("2026-10-18T19:42:55.804441+00:00")!
        let b = StreameroDate.parse("2026-10-18T19:42:55.804Z")!
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 0.001)
    }
}
