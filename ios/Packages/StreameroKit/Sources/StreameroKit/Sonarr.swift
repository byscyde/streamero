import Foundation

public struct Series: Decodable, Sendable, Identifiable, Hashable {
    public struct Statistics: Decodable, Sendable, Hashable {
        public var seasonCount: Int?
        public var episodeFileCount: Int?
        public var episodeCount: Int?
        public var totalEpisodeCount: Int?
        public var sizeOnDisk: Double?
        public var percentOfEpisodes: Double?
    }
    public struct Season: Decodable, Sendable, Hashable, Identifiable {
        public var seasonNumber: Int
        public var monitored: Bool?
        public var statistics: Statistics?
        public var id: Int { seasonNumber }
    }

    /// 0 for lookup results that aren't in the library yet.
    public var id: Int
    public var title: String
    public var year: Int?
    public var status: String?
    public var overview: String?
    public var network: String?
    public var monitored: Bool?
    public var images: [ArrImage]?
    public var statistics: Statistics?
    public var seasons: [Season]?
    public var qualityProfileId: Int?
    public var path: String?
    public var tvdbId: Int?
    public var genres: [String]?
    public var runtime: Int?
    public var nextAiring: Date?
    public var added: Date?

    enum CodingKeys: String, CodingKey { case id, title, year, status, overview, network, monitored, images, statistics, seasons, qualityProfileId, path, tvdbId, genres, runtime, nextAiring, added }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        network = try c.decodeIfPresent(String.self, forKey: .network)
        monitored = try c.decodeIfPresent(Bool.self, forKey: .monitored)
        images = try c.decodeIfPresent([ArrImage].self, forKey: .images)
        statistics = try c.decodeIfPresent(Statistics.self, forKey: .statistics)
        seasons = try c.decodeIfPresent([Season].self, forKey: .seasons)
        qualityProfileId = try c.decodeIfPresent(Int.self, forKey: .qualityProfileId)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        tvdbId = try c.decodeIfPresent(Int.self, forKey: .tvdbId)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        runtime = try c.decodeIfPresent(Int.self, forKey: .runtime)
        nextAiring = try c.decodeIfPresent(Date.self, forKey: .nextAiring)
        added = try c.decodeIfPresent(Date.self, forKey: .added)
    }

    public var isInLibrary: Bool { id > 0 }
    public var episodeProgress: Double { (statistics?.percentOfEpisodes ?? 0) / 100 }
}

public struct Episode: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var seriesId: Int?
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var title: String?
    public var airDateUtc: Date?
    public var hasFile: Bool?
    public var monitored: Bool?
    public var overview: String?
    public var series: Series?

    /// "S01E02"
    public var code: String { String(format: "S%02dE%02d", seasonNumber, episodeNumber) }
}

public struct SonarrClient: ArrService {
    public let client: ServiceClient
    public init(client: ServiceClient) { self.client = client }

    public func series() async throws -> [Series] { try await client.get("series") }
    public func series(_ id: Int) async throws -> Series { try await client.get("series/\(id)") }
    public func episodes(seriesId: Int) async throws -> [Episode] {
        try await client.get("episode", query: [URLQueryItem(name: "seriesId", value: String(seriesId))])
    }

    public func calendar(from start: Date, to end: Date) async throws -> [Episode] {
        try await client.get("calendar", query: [
            URLQueryItem(name: "start", value: ISODay.string(start)),
            URLQueryItem(name: "end", value: ISODay.string(end)),
            URLQueryItem(name: "includeSeries", value: "true"),
        ])
    }

    public func queue(pageSize: Int = 100) async throws -> ArrPage<QueueItem> {
        try await client.get("queue", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "includeSeries", value: "true"), URLQueryItem(name: "includeEpisode", value: "true"),
        ])
    }

    public func missing(pageSize: Int = 50) async throws -> ArrPage<Episode> {
        try await client.get("wanted/missing", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: "airDateUtc"), URLQueryItem(name: "sortDirection", value: "descending"),
            URLQueryItem(name: "includeSeries", value: "true"), URLQueryItem(name: "monitored", value: "true"),
        ])
    }

    public func history(pageSize: Int = 50) async throws -> ArrPage<HistoryRecord> {
        try await client.get("history", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: "date"), URLQueryItem(name: "sortDirection", value: "descending"),
            URLQueryItem(name: "includeSeries", value: "true"), URLQueryItem(name: "includeEpisode", value: "true"),
        ])
    }

    /// Raw lookup results (TVDB) — pass one to `add`.
    public func lookup(_ term: String) async throws -> [JSONValue] {
        try await client.get("series/lookup", query: [URLQueryItem(name: "term", value: term)])
    }

    @discardableResult
    public func add(_ lookup: JSONValue, qualityProfileId: Int, rootFolderPath: String, monitor: String = "all", searchNow: Bool = true) async throws -> Series {
        let body = ArrAdd.prepare(lookup, qualityProfileId: qualityProfileId, rootFolderPath: rootFolderPath, extra: [
            "seasonFolder": .bool(true),
            "addOptions": .object(["monitor": .string(monitor), "searchForMissingEpisodes": .bool(searchNow), "searchForCutoffUnmetEpisodes": .bool(false)]),
        ])
        return try await client.send(.post, "series", json: body)
    }

    public func setMonitored(seriesId: Int, _ monitored: Bool) async throws {
        try await updateRaw("series/\(seriesId)") { $0["monitored"] = .bool(monitored) }
    }

    public func setEpisodesMonitored(_ ids: [Int], _ monitored: Bool) async throws {
        try await client.perform(.put, "episode/monitor", json: ["episodeIds": JSONValue.array(ids.map(JSONValue.init)), "monitored": .bool(monitored)])
    }

    public func delete(seriesId: Int, deleteFiles: Bool) async throws {
        try await client.perform(.delete, "series/\(seriesId)", query: [URLQueryItem(name: "deleteFiles", value: String(deleteFiles))])
    }

    public func searchSeries(_ id: Int) async throws { try await command("SeriesSearch", ["seriesId": JSONValue(id)]) }
    public func searchSeason(seriesId: Int, season: Int) async throws {
        try await command("SeasonSearch", ["seriesId": JSONValue(seriesId), "seasonNumber": JSONValue(season)])
    }
    public func searchEpisodes(_ ids: [Int]) async throws { try await command("EpisodeSearch", ["episodeIds": .array(ids.map(JSONValue.init))]) }
    public func refreshSeries(_ id: Int) async throws { try await command("RefreshSeries", ["seriesId": JSONValue(id)]) }
}

/// yyyy-MM-dd in UTC, as the calendar endpoints expect.
public enum ISODay {
    public static func string(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
