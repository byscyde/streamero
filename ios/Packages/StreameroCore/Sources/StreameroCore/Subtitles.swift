import Foundation

public struct SubtitleCue: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
}

/// WebVTT parser for the client-side subtitle renderer (adjustable size, background, sync offset).
public enum WebVTTParser {
    public static func parse(_ input: String) -> [SubtitleCue] {
        let text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let idx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[idx].components(separatedBy: "-->")
            guard parts.count == 2, let start = timestamp(parts[0]), let end = timestamp(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""), end > start else { continue }
            let body = lines[(idx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: stripTags(body)))
        }
        return cues.sorted { $0.start < $1.start }
    }

    public static func timestamp(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let comps = s.split(separator: ":").map(String.init)
        guard comps.count == 2 || comps.count == 3, let secs = Double(comps.last!) else { return nil }
        let mins = Double(comps[comps.count - 2]) ?? 0
        let hours = comps.count == 3 ? (Double(comps[0]) ?? 0) : 0
        return hours * 3600 + mins * 60 + secs
    }

    static func stripTags(_ s: String) -> String {
        s.replacing(/<[^>]+>/, with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

public struct SubtitleTimeline: Sendable {
    public let cues: [SubtitleCue]
    public init(cues: [SubtitleCue]) { self.cues = cues }

    /// Text visible at `time`; a positive offset delays subtitles (they appear later).
    public func text(at time: TimeInterval, offset: TimeInterval = 0) -> String? {
        let t = time - offset
        // Binary search for the last cue starting at or before t, then scan back for overlaps.
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        var active: [String] = []
        var i = lo - 1
        while i >= 0, i >= lo - 8 {
            if cues[i].start <= t, t < cues[i].end { active.insert(cues[i].text, at: 0) }
            i -= 1
        }
        return active.isEmpty ? nil : active.joined(separator: "\n")
    }
}

/// Picks the subtitle track to enable automatically from the user's preferred languages.
public func autoSelectSubtitle<S>(_ tracks: [S], preferred: [String], alwaysOn: Bool, language: KeyPath<S, String>, isDefault: KeyPath<S, Bool>, forced: KeyPath<S, Bool>) -> S? {
    let norm = { (s: String) in s.lowercased().split(separator: "-").first.map(String.init) ?? s.lowercased() }
    let prefs = preferred.map(norm)
    if alwaysOn {
        for p in prefs { if let t = tracks.first(where: { norm($0[keyPath: language]) == p && !$0[keyPath: forced] }) { return t } }
        return tracks.first { $0[keyPath: isDefault] }
    }
    // Subtitles off: still show forced subtitles (e.g. foreign-language dialogue) in the user's language.
    for p in prefs { if let t = tracks.first(where: { norm($0[keyPath: language]) == p && $0[keyPath: forced] }) { return t } }
    return nil
}
