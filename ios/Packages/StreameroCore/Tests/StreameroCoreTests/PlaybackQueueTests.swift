import XCTest
@testable import StreameroCore

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

func makeTracks(_ n: Int) -> [Track] {
    (0..<n).map { Track(id: "t\($0)", title: "Track \($0)", durationMs: 180_000, artist: ArtistRef(id: "a\($0 % 3)", name: "Artist")) }
}

final class PlaybackQueueTests: XCTestCase {
    func testAdvanceAndRepeatModes() {
        var q = PlaybackQueue()
        q.load(makeTracks(3), startAt: 1)
        XCTAssertEqual(q.current?.track.id, "t1")
        XCTAssertEqual(q.advance(userInitiated: false)?.track.id, "t2")
        XCTAssertNil(q.advance(userInitiated: false), "repeat off stops at the end")
        q.repeatMode = .all
        XCTAssertEqual(q.advance(userInitiated: false)?.track.id, "t0")
        q.repeatMode = .one
        XCTAssertEqual(q.advance(userInitiated: false)?.track.id, "t0", "repeat one replays on auto-advance")
        XCTAssertEqual(q.advance(userInitiated: true)?.track.id, "t1", "but a user skip moves on")
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    func testPreviousRestartsAfterThreeSeconds() {
        var q = PlaybackQueue()
        q.load(makeTracks(3), startAt: 1)
        XCTAssertEqual(q.previousAction(position: 10), .restartCurrent)
        XCTAssertEqual(q.goBack(position: 1), .moveTo(0))
        XCTAssertEqual(q.goBack(position: 1), .restartCurrent)
        q.repeatMode = .all
        XCTAssertEqual(q.goBack(position: 0), .moveTo(2))
    }

    func testShuffleKeepsCurrentFirstAndRestoresOrder() {
        var rng = SeededRNG(state: 42)
        var q = PlaybackQueue()
        q.load(makeTracks(10), startAt: 4, using: &rng)
        q.setShuffle(true, using: &rng)
        XCTAssertEqual(q.current?.track.id, "t4")
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertEqual(Set(q.items.map(\.track.id)).count, 10)
        XCTAssertNotEqual(q.items.map(\.track.id), makeTracks(10).map(\.id))
        q.advance(userInitiated: true)
        let playing = q.current!.track.id
        q.append(makeTracks(1).map { var t = $0; t.id = "extra"; return t })
        q.setShuffle(false, using: &rng)
        XCTAssertEqual(q.items.map(\.track.id), makeTracks(10).map(\.id) + ["extra"])
        XCTAssertEqual(q.current?.track.id, playing)
    }

    func testLoadWithShuffleFlag() {
        var rng = SeededRNG(state: 7)
        var q = PlaybackQueue()
        q.load(makeTracks(5), startAt: 2, shuffle: true, using: &rng)
        XCTAssertTrue(q.shuffle)
        XCTAssertEqual(q.current?.track.id, "t2")
        q.load(makeTracks(5), startAt: 0, shuffle: false, using: &rng)
        XCTAssertFalse(q.shuffle)
        XCTAssertEqual(q.items.map(\.track.id), ["t0", "t1", "t2", "t3", "t4"])
    }

    func testQueueEditing() {
        var q = PlaybackQueue()
        q.load(makeTracks(4), startAt: 1)
        q.playNext([Track(id: "n", title: "Next", durationMs: 1, artist: ArtistRef(id: "x", name: "X"))])
        XCTAssertEqual(q.upNext.first?.track.id, "n")
        q.move(from: 2, to: 4)
        XCTAssertEqual(q.items.map(\.track.id), ["t0", "t1", "t2", "t3", "n"])
        XCTAssertEqual(q.current?.track.id, "t1")
        q.remove(itemId: q.items[0].id)
        XCTAssertEqual(q.current?.track.id, "t1")
        XCTAssertEqual(q.currentIndex, 0)
        q.remove(itemId: q.current!.id)
        XCTAssertEqual(q.current?.track.id, "t2", "removing the current entry makes the next one current")
        q.clearUpNext()
        XCTAssertEqual(q.items.count, 1)
        var liked = q.current!.track
        liked.isLiked = true
        q.updateTrack(liked)
        XCTAssertTrue(q.current!.track.isLiked)
    }

    func testSnapshotRoundTrip() throws {
        var q = PlaybackQueue()
        q.load(makeTracks(3), startAt: 2, context: PlaybackContext(type: "album", id: "x"))
        q.repeatMode = .all
        let snap = PlaybackSnapshot(queue: q, positionMs: 42_000)
        let data = try JSONEncoder.streamero.encode(snap)
        let back = try JSONDecoder.streamero.decode(PlaybackSnapshot.self, from: data)
        XCTAssertEqual(back.queue, q)
        XCTAssertEqual(back.positionMs, 42_000)
    }

    func testCrossfadeIsEqualPower() {
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            let g = crossfadeGains(progress: p)
            XCTAssertEqual(Double(g.outgoing * g.outgoing + g.incoming * g.incoming), 1, accuracy: 0.0001)
        }
        XCTAssertEqual(crossfadeGains(progress: 0).outgoing, 1)
        XCTAssertEqual(crossfadeGains(progress: 2).incoming, 1)
    }

    func testQualityPolicy() {
        let p = QualityPolicy(wifi: .lossless, cellular: .standard)
        XCTAssertEqual(p.profile(for: .wifi), .lossless)
        XCTAssertEqual(p.profile(for: .cellular), .standard)
        XCTAssertEqual(p.profile(for: .wifi, lowDataMode: true), .dataSaver)
    }
}
