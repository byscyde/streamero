import Foundation

/// The API emits ISO 8601 timestamps with milliseconds ("…T19:42:55.804Z") and, inside JSON
/// aggregates, PostgreSQL's microsecond/offset form ("…T19:42:55.804441+00:00"). Accept both.
public enum StreameroDate {
    public static func parse(_ string: String) -> Date? {
        var s = string
        // Normalise "+00:00" offsets and trim sub-millisecond precision, which ISO8601DateFormatter rejects.
        if let dot = s.firstIndex(of: ".") {
            let fracStart = s.index(after: dot)
            var end = fracStart
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let digits = s[fracStart..<end]
            let ms = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s = String(s[..<fracStart]) + ms + String(s[end...])
        }
        if s.hasSuffix("+00:00") { s = String(s.dropLast(6)) + "Z" }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        // Bare dates ("2024-02-02") for release dates.
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: s)
    }

    public static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

extension JSONDecoder {
    public static var streamero: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = StreameroDate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date: \(s)")
            }
            return date
        }
        return d
    }
}

extension JSONEncoder {
    public static var streamero: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(StreameroDate.format(date))
        }
        return e
    }
}
