import XCTest
@testable import StreameroCore

final class TextTimelineTests: XCTestCase {
    func testLRCParsingWithOffsetAndWords() {
        let t = LRCParser.parse("[ti:Song]\n[offset:500]\n[00:10.00]Second\n[00:05.50][00:20.00]Hook\n[00:12.00]<00:12.00>Hello <00:12.50>world")
        XCTAssertTrue(t.synced)
        XCTAssertEqual(t.lines.map(\.text), ["Hook", "Second", "Hello world", "Hook"])
        XCTAssertEqual(t.lines[0].start, 5.0, accuracy: 0.001)
        XCTAssertEqual(t.lines[2].words.map(\.text), ["Hello", "world"])
        XCTAssertNil(t.activeIndex(at: 1))
        XCTAssertEqual(t.activeIndex(at: 9.6), 1)
        XCTAssertEqual(t.activeIndex(at: 100), 3)
        XCTAssertEqual(t.wordsSung(at: 11.8), 1)
        XCTAssertEqual(t.wordsSung(at: 12.1), 2)
        XCTAssertEqual(t.lineProgress(at: 7.25, trackDuration: 30), 0.5, accuracy: 0.01)
    }

    func testPlainLyrics() {
        let t = LRCParser.parse("Just words\nNo timing")
        XCTAssertFalse(t.synced)
        XCTAssertEqual(t.lines.count, 2)
        XCTAssertNil(t.activeIndex(at: 5))
    }

    func testServerLyricsResponse() {
        let r = LyricsResponse(trackId: "t", synced: true, language: nil, lines: [.init(startMs: 1000, text: "A", words: nil), .init(startMs: 4000, text: "B", words: nil)], attribution: .init(source: nil, license: nil))
        let t = LyricsTimeline(response: r)
        XCTAssertEqual(t.activeIndex(at: 4.5), 1)
    }

    func testWebVTTAndOffsets() {
        let vtt = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000\n\n1\n00:00:01.000 --> 00:00:03.000 align:start\n<i>Hello</i> &amp; welcome\n\n00:02.500 --> 00:04.000\nOverlap\n\n00:10.000 --> 00:09.000\nbad\n"
        let cues = WebVTTParser.parse(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello & welcome")
        let tl = SubtitleTimeline(cues: cues)
        XCTAssertNil(tl.text(at: 0.5))
        XCTAssertEqual(tl.text(at: 2.7), "Hello & welcome\nOverlap")
        XCTAssertEqual(tl.text(at: 3.5), "Overlap")
        XCTAssertEqual(tl.text(at: 1.5, offset: 1), nil, "a +1 s offset delays the first cue")
        XCTAssertEqual(tl.text(at: 2.1, offset: 1), "Hello & welcome")
        XCTAssertEqual(WebVTTParser.timestamp("01:02:03,500"), 3723.5)
    }

    func testSubtitleAutoSelection() {
        struct S { var language: String; var isDefault: Bool; var forced: Bool }
        let tracks = [S(language: "en", isDefault: true, forced: false), S(language: "hr", isDefault: false, forced: false), S(language: "hr", isDefault: false, forced: true)]
        let pick = { (prefs: [String], on: Bool) in autoSelectSubtitle(tracks, preferred: prefs, alwaysOn: on, language: \.language, isDefault: \.isDefault, forced: \.forced) }
        XCTAssertEqual(pick(["hr-HR", "en"], true)?.language, "hr")
        XCTAssertEqual(pick(["hr"], true)?.forced, false)
        XCTAssertEqual(pick(["de"], true)?.language, "en")
        XCTAssertEqual(pick(["hr"], false)?.forced, true, "forced subtitles show even when subtitles are off")
        XCTAssertNil(pick(["de"], false))
    }

    func testTimelineTiles() {
        let t = timelineTile(at: 125, interval: 5, columns: 10, rows: 10, tileWidth: 160, tileHeight: 90, sheetCount: 2)
        XCTAssertEqual(t, TimelineTile(sheet: 0, column: 5, row: 2, x: 800, y: 180))
        XCTAssertEqual(timelineTile(at: 600, interval: 5, columns: 10, rows: 10, tileWidth: 160, tileHeight: 90, sheetCount: 2)?.sheet, 1)
        XCTAssertEqual(timelineTile(at: 99999, interval: 5, columns: 10, rows: 10, tileWidth: 160, tileHeight: 90, sheetCount: 2)?.sheet, 1)
    }
}
