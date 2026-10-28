import Foundation

// Bazarr's REST API (/api, X-API-KEY). Responses are wrapped in {"data": …}.

public struct BazarrData<T: Decodable & Sendable>: Decodable, Sendable {
    public var data: T
    public var total: Int?
}

public struct BazarrStatus: Decodable, Sendable {
    public var bazarrVersion: String?
    public var sonarrVersion: String?
    public var radarrVersion: String?
    public var operatingSystem: String?

    enum CodingKeys: String, CodingKey {
        case bazarrVersion = "bazarr_version", sonarrVersion = "sonarr_version", radarrVersion = "radarr_version", operatingSystem = "operating_system"
    }
}

public struct BazarrBadges: Decodable, Sendable {
    public var episodes: Int?
    public var movies: Int?
    public var providers: Int?
    public var status: Int?
}

public struct SubtitleLanguage: Decodable, Sendable, Hashable {
    public var name: String?
    public var code2: String?
    public var code3: String?
    public var forced: Bool?
    public var hi: Bool?

    enum CodingKeys: String, CodingKey { case name, code2, code3, forced, hi }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        code2 = try c.decodeIfPresent(String.self, forKey: .code2)
        code3 = try c.decodeIfPresent(String.self, forKey: .code3)
        forced = Self.flag(c, .forced)
        hi = Self.flag(c, .hi)
    }

    /// Bazarr has sent these as booleans and as "True"/"False" strings across versions.
    private static func flag(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let value = try? c.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return text.lowercased() == "true" }
        return nil
    }

    public var label: String {
        var text = name ?? code2 ?? "?"
        if forced == true { text += " (forced)" }
        if hi == true { text += " (HI)" }
        return text
    }
}

public struct WantedEpisode: Decodable, Sendable, Identifiable, Hashable {
    public var seriesTitle: String?
    public var episodeNumber: String?
    public var episodeTitle: String?
    public var missingSubtitles: [SubtitleLanguage]
    public var sonarrSeriesId: Int
    public var sonarrEpisodeId: Int
    public var id: Int { sonarrEpisodeId }

    enum CodingKeys: String, CodingKey {
        case seriesTitle, episodeNumber = "episode_number", episodeTitle, missingSubtitles = "missing_subtitles", sonarrSeriesId, sonarrEpisodeId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seriesTitle = try? c.decodeIfPresent(String.self, forKey: .seriesTitle)
        episodeNumber = try? c.decodeIfPresent(String.self, forKey: .episodeNumber)
        episodeTitle = try? c.decodeIfPresent(String.self, forKey: .episodeTitle)
        missingSubtitles = (try? c.decodeIfPresent([SubtitleLanguage].self, forKey: .missingSubtitles)) ?? []
        sonarrSeriesId = try c.decode(Int.self, forKey: .sonarrSeriesId)
        sonarrEpisodeId = try c.decode(Int.self, forKey: .sonarrEpisodeId)
    }
}

public struct WantedMovie: Decodable, Sendable, Identifiable, Hashable {
    public var title: String?
    public var missingSubtitles: [SubtitleLanguage]
    public var radarrId: Int
    public var id: Int { radarrId }

    enum CodingKeys: String, CodingKey { case title, missingSubtitles = "missing_subtitles", radarrId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        missingSubtitles = (try? c.decodeIfPresent([SubtitleLanguage].self, forKey: .missingSubtitles)) ?? []
        radarrId = try c.decode(Int.self, forKey: .radarrId)
    }
}

public struct SubtitleHistoryEntry: Decodable, Sendable, Identifiable, Hashable {
    public var seriesTitle: String?
    public var episodeNumber: String?
    public var episodeTitle: String?
    public var title: String?
    public var timestamp: String?
    public var description: String?
    public var language: SubtitleLanguage?
    public var provider: String?
    public var action: Int?
    public var id: String { [seriesTitle, episodeNumber, title, timestamp, description].compactMap { $0 }.joined(separator: "|") }

    enum CodingKeys: String, CodingKey { case seriesTitle, episodeNumber = "episode_number", episodeTitle, title, timestamp, description, language, provider, action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seriesTitle = try? c.decodeIfPresent(String.self, forKey: .seriesTitle)
        episodeNumber = try? c.decodeIfPresent(String.self, forKey: .episodeNumber)
        episodeTitle = try? c.decodeIfPresent(String.self, forKey: .episodeTitle)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        language = try? c.decodeIfPresent(SubtitleLanguage.self, forKey: .language)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        action = try? c.decodeIfPresent(Int.self, forKey: .action)
    }

    public var displayTitle: String {
        if let seriesTitle { return [seriesTitle, episodeNumber].compactMap { $0 }.joined(separator: " ") }
        return title ?? "Unknown"
    }
}

public struct SubtitleProvider: Decodable, Sendable, Identifiable, Hashable {
    public var name: String
    public var status: String?
    public var retry: String?
    public var id: String { name }
}

public struct BazarrTask: Decodable, Sendable, Identifiable, Hashable {
    public var name: String
    public var interval: String?
    public var nextRunIn: String?
    public var jobId: String
    public var jobRunning: Bool?
    public var id: String { jobId }

    enum CodingKeys: String, CodingKey { case name, interval, nextRunIn = "next_run_in", jobId = "job_id", jobRunning = "job_running" }
}

public struct BazarrHealthIssue: Decodable, Sendable, Hashable {
    public var object: String?
    public var issue: String?
}

public struct BazarrClient: Sendable {
    public let client: ServiceClient
    public init(client: ServiceClient) { self.client = client }

    public func status() async throws -> BazarrStatus { try await client.get("system/status", as: BazarrData<BazarrStatus>.self).data }
    public func badges() async throws -> BazarrBadges { try await client.get("badges") }
    public func health() async throws -> [BazarrHealthIssue] { try await client.get("system/health", as: BazarrData<[BazarrHealthIssue]>.self).data }

    public func wantedEpisodes(length: Int = 50) async throws -> BazarrData<[WantedEpisode]> {
        try await client.get("episodes/wanted", query: [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "length", value: String(length))])
    }

    public func wantedMovies(length: Int = 50) async throws -> BazarrData<[WantedMovie]> {
        try await client.get("movies/wanted", query: [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "length", value: String(length))])
    }

    public func episodeHistory(length: Int = 50) async throws -> [SubtitleHistoryEntry] {
        try await client.get("episodes/history", query: [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "length", value: String(length))], as: BazarrData<[SubtitleHistoryEntry]>.self).data
    }

    public func movieHistory(length: Int = 50) async throws -> [SubtitleHistoryEntry] {
        try await client.get("movies/history", query: [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "length", value: String(length))], as: BazarrData<[SubtitleHistoryEntry]>.self).data
    }

    public func providers() async throws -> [SubtitleProvider] { try await client.get("providers", as: BazarrData<[SubtitleProvider]>.self).data }
    public func resetProviders() async throws { try await client.perform(.post, "providers", query: [URLQueryItem(name: "action", value: "reset")]) }

    public func tasks() async throws -> [BazarrTask] { try await client.get("system/tasks", as: BazarrData<[BazarrTask]>.self).data }
    public func run(task: String) async throws { try await client.perform(.post, "system/tasks", query: [URLQueryItem(name: "taskid", value: task)]) }

    /// Searches and downloads the best subtitle for one episode and language.
    public func downloadSubtitle(episode: WantedEpisode, language: SubtitleLanguage) async throws {
        try await client.perform(.patch, "episodes/subtitles", query: [
            URLQueryItem(name: "seriesid", value: String(episode.sonarrSeriesId)),
            URLQueryItem(name: "episodeid", value: String(episode.sonarrEpisodeId)),
            URLQueryItem(name: "language", value: language.code2 ?? ""),
            URLQueryItem(name: "forced", value: language.forced == true ? "True" : "False"),
            URLQueryItem(name: "hi", value: language.hi == true ? "True" : "False"),
        ])
    }

    public func downloadSubtitle(movie: WantedMovie, language: SubtitleLanguage) async throws {
        try await client.perform(.patch, "movies/subtitles", query: [
            URLQueryItem(name: "radarrid", value: String(movie.radarrId)),
            URLQueryItem(name: "language", value: language.code2 ?? ""),
            URLQueryItem(name: "forced", value: language.forced == true ? "True" : "False"),
            URLQueryItem(name: "hi", value: language.hi == true ? "True" : "False"),
        ])
    }
}
