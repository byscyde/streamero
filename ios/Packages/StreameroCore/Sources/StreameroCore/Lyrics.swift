import Foundation

public struct LyricLine: Sendable, Hashable, Identifiable {
    public struct Word: Sendable, Hashable { public var start: TimeInterval; public var text: String }
    public var id: Int
    public var start: TimeInterval
    public var text: String
    public var words: [Word]
}

/// Time-indexed lyrics. `start < 0` means unsynchronised (plain) lyrics.
public struct LyricsTimeline: Sendable, Equatable {
    public let lines: [LyricLine]
    public let synced: Bool

    public init(lines: [LyricLine], synced: Bool) {
        self.lines = synced ? lines.sorted { $0.start < $1.start } : lines
        self.synced = synced
    }

    public init(response: LyricsResponse) {
        let lines = response.lines.enumerated().map { i, l in
            LyricLine(id: i, start: TimeInterval(l.startMs) / 1000, text: l.text,
                      words: (l.words ?? []).map { .init(start: TimeInterval($0.startMs) / 1000, text: $0.text) })
        }
        self.init(lines: lines, synced: response.synced)
    }

    /// Index of the line active at `time` (binary search), or nil before the first line.
    public func activeIndex(at time: TimeInterval) -> Int? {
        guard synced, !lines.isEmpty, time >= lines[0].start else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].start <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 0...1 progress through the active line, for karaoke-style highlighting.
    public func lineProgress(at time: TimeInterval, trackDuration: TimeInterval) -> Double {
        guard let i = activeIndex(at: time) else { return 0 }
        let start = lines[i].start
        let end = i + 1 < lines.count ? lines[i + 1].start : max(start + 1, trackDuration)
        return min(1, max(0, (time - start) / max(0.001, end - start)))
    }

    /// Number of words already sung in the active line (for word-level timing).
    public func wordsSung(at time: TimeInterval) -> Int {
        guard let i = activeIndex(at: time) else { return 0 }
        return lines[i].words.filter { $0.start <= time }.count
    }
}

/// Client-side LRC parser (mirrors the server's), used for locally stored lyrics.
public enum LRCParser {
    public static func parse(_ input: String) -> LyricsTimeline {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0
        var synced = false
        let stamp = /\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/
        let word = /<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>/
        for raw in input.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: true) {
            var line = Substring(raw.trimmingCharacters(in: .whitespaces))
            if let m = line.wholeMatch(of: /\[([a-zA-Z]+):(.*)\]/) {
                if m.1.lowercased() == "offset" { offset = (Double(m.2.trimmingCharacters(in: .whitespaces)) ?? 0) / 1000 }
                continue
            }
            var starts: [TimeInterval] = []
            while let m = line.prefixMatch(of: stamp) {
                starts.append(seconds(m.1, m.2, m.3))
                line = line[m.range.upperBound...]
            }
            if starts.isEmpty {
                lines.append(LyricLine(id: lines.count, start: -1, text: String(line), words: []))
                continue
            }
            synced = true
            var words: [LyricLine.Word] = []
            var text = ""
            var rest = line
            var pendingStart: TimeInterval?
            while let m = rest.firstMatch(of: word) {
                let before = rest[..<m.range.lowerBound].trimmingCharacters(in: .whitespaces)
                if let s = pendingStart, !before.isEmpty { words.append(.init(start: max(0, s - offset), text: before)) }
                if !before.isEmpty { text += (text.isEmpty ? "" : " ") + before }
                pendingStart = seconds(m.1, m.2, m.3)
                rest = rest[m.range.upperBound...]
            }
            let tail = rest.trimmingCharacters(in: .whitespaces)
            if let s = pendingStart, !tail.isEmpty { words.append(.init(start: max(0, s - offset), text: tail)) }
            if !tail.isEmpty { text += (text.isEmpty ? "" : " ") + tail }
            for s in starts { lines.append(LyricLine(id: lines.count, start: max(0, s - offset), text: text, words: words)) }
        }
        if !synced { return LyricsTimeline(lines: lines, synced: false) }
        let timed = lines.filter { $0.start >= 0 }.sorted { $0.start < $1.start }.enumerated().map { i, l in
            LyricLine(id: i, start: l.start, text: l.text, words: l.words)
        }
        return LyricsTimeline(lines: timed, synced: true)
    }

    private static func seconds(_ m: Substring, _ s: Substring, _ f: Substring?) -> TimeInterval {
        let frac = f.map { Double("0." + $0) ?? 0 } ?? 0
        return (Double(m) ?? 0) * 60 + (Double(s) ?? 0) + frac
    }
}
