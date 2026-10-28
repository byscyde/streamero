import Foundation

/// A download in any *arr queue, normalised for one combined list.
public struct ActivityDownload: Sendable, Identifiable, Hashable {
    public var id: String
    public var serviceId: UUID
    public var kind: ServiceKind
    public var queueId: Int
    public var title: String
    public var subtitle: String?
    public var progress: Double
    public var status: String
    public var timeLeft: String?
    public var sizeLeft: Double?
    public var problem: String?
    public var client: String?

    public init(serviceId: UUID, kind: ServiceKind, item: QueueItem) {
        self.id = "\(serviceId)|\(item.id)"
        self.serviceId = serviceId
        self.kind = kind
        self.queueId = item.id
        if let series = item.series {
            self.title = series.title
            self.subtitle = item.episode.map { [$0.code, $0.title].compactMap { $0 }.joined(separator: " · ") }
        } else if let movie = item.movie {
            self.title = movie.year.map { "\(movie.title) (\($0))" } ?? movie.title
            self.subtitle = item.quality?.name
        } else if let artist = item.artist {
            self.title = artist.artistName
            self.subtitle = item.album?.title
        } else {
            self.title = item.title ?? "Download"
            self.subtitle = nil
        }
        self.progress = item.progress
        self.status = (item.trackedDownloadState ?? item.status ?? "queued").capitalized
        self.timeLeft = item.timeleft.flatMap(Self.compactTimeLeft)
        self.sizeLeft = item.sizeleft
        self.problem = item.hasProblem ? (item.problemText ?? "Needs attention") : nil
        self.client = item.downloadClient
    }

    /// "01:02:03" or "1.02:03:04" (days) → "1h 2m" / "1d 2h"; nil for zero.
    static func compactTimeLeft(_ raw: String) -> String? {
        var days = 0
        var clock = raw
        if let dot = raw.firstIndex(of: "."), raw[..<dot].allSatisfy(\.isNumber), raw.filter({ $0 == ":" }).count == 2 {
            days = Int(raw[..<dot]) ?? 0
            clock = String(raw[raw.index(after: dot)...])
        }
        let parts = clock.split(separator: ":").compactMap { Int($0.prefix { $0.isNumber }) }
        guard parts.count == 3 else { return nil }
        let (h, m, s) = (parts[0], parts[1], parts[2])
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return s > 0 ? "\(s)s" : nil
    }
}

/// Something upcoming from Sonarr, Radarr or Lidarr.
public struct CalendarEntry: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case episode, movie, album }
    public var id: String
    public var kind: Kind
    public var date: Date
    public var title: String
    public var subtitle: String?
    public var posterURL: URL?
    public var hasFile: Bool

    public static func from(_ episode: Episode) -> CalendarEntry? {
        guard let date = episode.airDateUtc, date > .distantPast else { return nil }
        return CalendarEntry(id: "e\(episode.id)", kind: .episode, date: date, title: episode.series?.title ?? "Episode",
                             subtitle: [episode.code, episode.title].compactMap { $0 }.joined(separator: " · "),
                             posterURL: episode.series?.images?.poster, hasFile: episode.hasFile == true)
    }

    public static func from(_ movie: Movie, now: Date = Date()) -> CalendarEntry? {
        let dates = [(movie.inCinemas, "In cinemas"), (movie.digitalRelease, "Digital release"), (movie.physicalRelease, "Physical release")]
        guard let next = dates.compactMap({ d, label in d.map { ($0, label) } }).filter({ $0.0 > now.addingTimeInterval(-86_400) }).min(by: { $0.0 < $1.0 }) else { return nil }
        return CalendarEntry(id: "m\(movie.id)", kind: .movie, date: next.0, title: movie.title, subtitle: next.1,
                             posterURL: movie.images?.poster, hasFile: movie.hasFile == true)
    }

    public static func from(_ album: Album) -> CalendarEntry? {
        guard let date = album.releaseDate, date > .distantPast else { return nil }
        return CalendarEntry(id: "a\(album.id)", kind: .album, date: date, title: album.title,
                             subtitle: album.artist?.artistName ?? album.albumType, posterURL: album.images?.poster ?? album.artist?.images?.poster,
                             hasFile: (album.statistics?.percentOfTracks ?? 0) >= 100)
    }

    /// Groups entries by calendar day (local time), days in ascending order.
    public static func groupedByDay(_ entries: [CalendarEntry], calendar: Calendar = .current) -> [(day: Date, entries: [CalendarEntry])] {
        let groups = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted().map { day in (day, groups[day]!.sorted { $0.date < $1.date }) }
    }
}

/// A health message from any service.
public struct HealthIssue: Sendable, Identifiable, Hashable {
    public var id: String
    public var service: String
    public var severity: HealthSeverity
    public var message: String
    public var wikiURL: URL?

    public init(service: String, health: ArrHealth) {
        self.id = "\(service)|\(health.id)"
        self.service = service
        self.severity = health.severity
        self.message = health.message
        self.wikiURL = health.wikiUrl.flatMap(URL.init(string:))
    }

    public init(service: String, severity: HealthSeverity, message: String) {
        self.id = "\(service)|\(message)"
        self.service = service
        self.severity = severity
        self.message = message
        self.wikiURL = nil
    }

    public static func sorted(_ issues: [HealthIssue]) -> [HealthIssue] {
        issues.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.service < $1.service }
    }
}

/// Disk usage reported by several *arr apps for the same disks: de-duplicated by path.
public enum DiskSummary {
    public static func unique(_ disks: [DiskSpace]) -> [DiskSpace] {
        var seen = Set<String>()
        return disks.filter { disk in
            let key = disk.path ?? disk.label ?? "\(disk.totalSpace)"
            return disk.totalSpace > 0 && seen.insert(key).inserted
        }.sorted { $0.usedFraction > $1.usedFraction }
    }
}

public enum Format {
    public static func bytes(_ value: Double?) -> String {
        guard let value, value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = value
        var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    /// Jellyfin ticks (100 ns) → "1:02:03" / "4:05".
    public static func ticks(_ ticks: Int64?) -> String {
        guard let ticks, ticks > 0 else { return "0:00" }
        let total = Int(ticks / 10_000_000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// Jellyfin uses 0001-01-01 for "never".
    public static func isRealDate(_ date: Date?) -> Bool { (date ?? .distantPast) > Date(timeIntervalSince1970: 0) }
}
