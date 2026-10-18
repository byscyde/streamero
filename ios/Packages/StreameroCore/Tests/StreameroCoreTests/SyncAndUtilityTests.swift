import Foundation
import XCTest
@testable import StreameroCore

final class SyncAndUtilityTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Hasher.hex(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hasher.hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Hasher.hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Streaming in odd-sized chunks equals one-shot hashing.
        let big = Data((0..<200_003).map { UInt8($0 % 251) })
        var h = SHA256Hasher()
        var i = 0
        while i < big.count { let n = min(777, big.count - i); h.update(big.subdata(in: i..<(i + n))); i += n }
        XCTAssertEqual(h.finalize(), SHA256Hasher.hex(of: big))
    }

    func testSHA256OfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try SHA256Hasher.hex(ofFile: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testLibraryChangeQueueCoalesces() {
        var q = LibraryChangeQueue()
        let t0 = Date(timeIntervalSince1970: 1000)
        q.record(LibraryChange(type: .track, id: "a", op: .add, at: t0))
        q.record(LibraryChange(type: .track, id: "a", op: .remove, at: t0.addingTimeInterval(1)))
        q.record(LibraryChange(type: .album, id: "a", op: .add, at: t0.addingTimeInterval(2)))
        XCTAssertEqual(q.pending.count, 2)
        XCTAssertFalse(q.overlay(type: .track, id: "a", serverValue: true))
        XCTAssertTrue(q.overlay(type: .album, id: "a", serverValue: false))
        XCTAssertTrue(q.overlay(type: .artist, id: "z", serverValue: true))
        let sent = q.batch()
        q.record(LibraryChange(type: .track, id: "a", op: .add, at: t0.addingTimeInterval(3)))
        q.acknowledge(sent)
        XCTAssertEqual(q.pending.map(\.op), [.add], "a newer edit made during the request survives the acknowledgement")
    }

    func testListeningSessionCountsOnlyPlayingTime() {
        let start = Date(timeIntervalSince1970: 0)
        var s = ListeningSession(trackId: "t", startedAt: start, context: PlaybackContext(type: "album", id: "7c9e6679-7425-40de-944b-e07fc1f90ae7"))
        s.resume(at: start)
        s.pause(at: start.addingTimeInterval(20))
        s.resume(at: start.addingTimeInterval(100))
        let e = s.finish(completed: false, deviceId: "d", at: start.addingTimeInterval(115))
        XCTAssertEqual(e?.durationPlayedMs, 35_000)
        XCTAssertEqual(e?.contextType, "album")
        XCTAssertNil(ListeningSession(trackId: "t", startedAt: start, context: nil).finish(completed: false, deviceId: nil, at: start))
        var v = ListeningSession(trackId: "t", startedAt: start, context: PlaybackContext(type: "video", id: "vid"))
        v.resume(at: start)
        let ve = v.finish(completed: true, deviceId: nil, at: start.addingTimeInterval(5))
        XCTAssertEqual(ve?.videoId, "vid")
        XCTAssertNil(ve?.trackId)
    }

    func testSleepTimer() {
        let now = Date(timeIntervalSince1970: 0)
        let s = SleepTimerState(option: .minutes(15), now: now)
        XCTAssertEqual(s.remaining(now: now), 900)
        XCTAssertFalse(s.isDue(now: now.addingTimeInterval(899)))
        XCTAssertTrue(s.isDue(now: now.addingTimeInterval(900)))
        XCTAssertEqual(s.fadeVolume(now: now.addingTimeInterval(895)), 0.5, accuracy: 0.001)
        XCTAssertNil(SleepTimerState(option: .endOfTrack).fireDate)
        XCTAssertEqual(SleepTimerOption.minutes(90).title, "1 h 30 min")
    }

    func testFormatting() {
        XCTAssertEqual(Format.time(187), "3:07")
        XCTAssertEqual(Format.time(3723), "1:02:03")
        XCTAssertEqual(Format.time(-42), "-0:42")
        XCTAssertEqual(Format.longDuration(ms: 4_320_000), "1 h 12 min")
        XCTAssertEqual(Format.bytes(1_500_000), "1.5 MB")
        XCTAssertEqual(Format.count(1, "song"), "1 song")
        XCTAssertEqual(SourceQuality(codec: "flac", lossless: true, sampleRate: 44100, bitDepth: 16).summary, "FLAC · 16-bit / 44.1 kHz")
        XCTAssertEqual(SourceQuality(codec: "aac", lossless: false, bitrateKbps: 256).summary, "AAC · 256 kbps")
    }
}
