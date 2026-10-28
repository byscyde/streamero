import Foundation

// Jellyseerr and Overseerr share the same API (/api/v1, X-Api-Key).

public struct SeerrStatus: Decodable, Sendable {
    public var version: String?
    public var commitTag: String?
    public var updateAvailable: Bool?
}

public struct SeerrUser: Decodable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var displayName: String?
    public var username: String?
    public var jellyfinUsername: String?
    public var plexUsername: String?
    public var email: String?
    public var avatar: String?
    public var requestCount: Int?
    public var name: String { [displayName, jellyfinUsername, plexUsername, username, email].compactMap { $0 }.first { !$0.isEmpty } ?? "User \(id)" }
}

/// Media availability as reported by Seerr.
public enum SeerrMediaStatus: Int, Sendable {
    case unknown = 1, pending, processing, partiallyAvailable, available, deleted
    public var title: String {
        switch self {
        case .unknown: "Not requested"
        case .pending: "Pending"
        case .processing: "Processing"
        case .partiallyAvailable: "Partially available"
        case .available: "Available"
        case .deleted: "Deleted"
        }
    }
}

public struct SeerrMedia: Decodable, Sendable, Hashable {
    public var id: Int?
    public var tmdbId: Int?
    public var tvdbId: Int?
    public var status: Int?
    public var mediaType: String?
    public var mediaStatus: SeerrMediaStatus { SeerrMediaStatus(rawValue: status ?? 1) ?? .unknown }
}

public enum SeerrRequestStatus: Int, Sendable {
    case pending = 1, approved, declined, failed, completed
    public var title: String {
        switch self {
        case .pending: "Pending approval"
        case .approved: "Approved"
        case .declined: "Declined"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }
}

public struct SeerrRequest: Decodable, Sendable, Identifiable, Hashable {
    public struct Season: Decodable, Sendable, Hashable { public var seasonNumber: Int; public var status: Int? }
    public var id: Int
    public var status: Int
    public var createdAt: Date?
    public var updatedAt: Date?
    public var type: String
    public var is4k: Bool?
    public var media: SeerrMedia?
    public var requestedBy: SeerrUser?
    public var modifiedBy: SeerrUser?
    public var seasons: [Season]?

    public var requestStatus: SeerrRequestStatus { SeerrRequestStatus(rawValue: status) ?? .pending }
    public var isMovie: Bool { type == "movie" }
}

public struct SeerrPageInfo: Decodable, Sendable { public var pages: Int?; public var pageSize: Int?; public var results: Int?; public var page: Int? }

public struct SeerrPage<T: Decodable & Sendable>: Decodable, Sendable {
    public var pageInfo: SeerrPageInfo?
    public var results: [T]
}

public struct SeerrRequestCounts: Decodable, Sendable {
    public var total: Int?
    public var movie: Int?
    public var tv: Int?
    public var pending: Int?
    public var approved: Int?
    public var declined: Int?
    public var processing: Int?
    public var available: Int?
}

public struct SeerrSearchResult: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var mediaType: String
    public var title: String?
    public var name: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var releaseDate: String?
    public var firstAirDate: String?
    public var overview: String?
    public var voteAverage: Double?
    public var mediaInfo: SeerrMedia?

    public var displayTitle: String { title ?? name ?? "Untitled" }
    public var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
    public var posterURL: URL? { TMDB.image(posterPath) }
    public var isRequestable: Bool { mediaType == "movie" || mediaType == "tv" }
}

public struct SeerrMovieDetails: Decodable, Sendable, Hashable {
    public var id: Int
    public var title: String?
    public var releaseDate: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var overview: String?
    public var runtime: Int?
    public var mediaInfo: SeerrMedia?
}

public struct SeerrTVDetails: Decodable, Sendable, Hashable {
    public struct Season: Decodable, Sendable, Hashable { public var seasonNumber: Int; public var name: String?; public var episodeCount: Int? }
    public var id: Int
    public var name: String?
    public var firstAirDate: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var overview: String?
    public var numberOfSeasons: Int?
    public var seasons: [Season]?
    public var mediaInfo: SeerrMedia?
}

/// Title and artwork for a request (requests themselves carry only TMDB ids).
public struct SeerrTitle: Sendable, Hashable {
    public var title: String
    public var year: String?
    public var posterURL: URL?
    public var overview: String?
}

public struct SeerrIssue: Decodable, Sendable, Identifiable, Hashable {
    public struct Comment: Decodable, Sendable, Hashable { public var id: Int?; public var message: String?; public var user: SeerrUser? }
    public var id: Int
    public var issueType: Int
    public var status: Int
    public var problemSeason: Int?
    public var problemEpisode: Int?
    public var createdAt: Date?
    public var media: SeerrMedia?
    public var createdBy: SeerrUser?
    public var comments: [Comment]?

    public var typeTitle: String { [1: "Video", 2: "Audio", 3: "Subtitles"][issueType] ?? "Other" }
    public var isOpen: Bool { status == 1 }
}

public enum TMDB {
    public static func image(_ path: String?, size: String = "w342") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path.hasPrefix("/") ? path : "/" + path)")
    }
}

public enum SeerrRequestFilter: String, CaseIterable, Sendable, Identifiable {
    case pending, approved, processing, available, unavailable, failed, all
    public var id: String { rawValue }
    public var title: String { rawValue == "all" ? "All" : rawValue.capitalized }
}

public struct SeerrClient: Sendable {
    public let client: ServiceClient
    public init(client: ServiceClient) { self.client = client }

    public func status() async throws -> SeerrStatus { try await client.get("status") }
    public func counts() async throws -> SeerrRequestCounts { try await client.get("request/count") }

    public func requests(filter: SeerrRequestFilter = .pending, take: Int = 30, skip: Int = 0) async throws -> SeerrPage<SeerrRequest> {
        try await client.get("request", query: [
            URLQueryItem(name: "take", value: String(take)), URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "filter", value: filter.rawValue), URLQueryItem(name: "sort", value: "added"),
        ])
    }

    public func approve(_ id: Int) async throws { try await client.perform(.post, "request/\(id)/approve") }
    public func decline(_ id: Int) async throws { try await client.perform(.post, "request/\(id)/decline") }
    public func delete(_ id: Int) async throws { try await client.perform(.delete, "request/\(id)") }
    public func retry(_ id: Int) async throws { try await client.perform(.post, "request/\(id)/retry") }

    public func movie(_ tmdbId: Int) async throws -> SeerrMovieDetails { try await client.get("movie/\(tmdbId)") }
    public func tv(_ tmdbId: Int) async throws -> SeerrTVDetails { try await client.get("tv/\(tmdbId)") }

    /// Title, year and poster for a request.
    public func title(for request: SeerrRequest) async throws -> SeerrTitle {
        guard let tmdbId = request.media?.tmdbId else { return SeerrTitle(title: "Unknown") }
        if request.isMovie {
            let m = try await movie(tmdbId)
            return SeerrTitle(title: m.title ?? "Untitled", year: m.releaseDate.map { String($0.prefix(4)) }, posterURL: TMDB.image(m.posterPath), overview: m.overview)
        }
        let t = try await tv(tmdbId)
        return SeerrTitle(title: t.name ?? "Untitled", year: t.firstAirDate.map { String($0.prefix(4)) }, posterURL: TMDB.image(t.posterPath), overview: t.overview)
    }

    public func search(_ query: String, page: Int = 1) async throws -> [SeerrSearchResult] {
        let result: SeerrSearchPage = try await client.get("search", query: [URLQueryItem(name: "query", value: query), URLQueryItem(name: "page", value: String(page))])
        return result.results.filter(\.isRequestable)
    }

    public func trending(page: Int = 1) async throws -> [SeerrSearchResult] {
        let result: SeerrSearchPage = try await client.get("discover/trending", query: [URLQueryItem(name: "page", value: String(page))])
        return result.results.filter(\.isRequestable)
    }

    /// Requests a movie, or all regular seasons of a series.
    public func request(_ item: SeerrSearchResult, is4k: Bool = false) async throws {
        if item.mediaType == "movie" {
            try await client.perform(.post, "request", json: SeerrNewRequest(mediaType: "movie", mediaId: item.id, seasons: nil, is4k: is4k))
        } else {
            let details = try await tv(item.id)
            let seasons = (details.seasons ?? []).map(\.seasonNumber).filter { $0 > 0 }
            try await client.perform(.post, "request", json: SeerrNewRequest(mediaType: "tv", mediaId: item.id, seasons: seasons.isEmpty ? [1] : seasons, is4k: is4k))
        }
    }

    public func issues(openOnly: Bool = true, take: Int = 30) async throws -> SeerrPage<SeerrIssue> {
        try await client.get("issue", query: [
            URLQueryItem(name: "take", value: String(take)), URLQueryItem(name: "skip", value: "0"),
            URLQueryItem(name: "filter", value: openOnly ? "open" : "all"), URLQueryItem(name: "sort", value: "added"),
        ])
    }

    public func resolveIssue(_ id: Int) async throws { try await client.perform(.post, "issue/\(id)/resolved") }
    public func commentIssue(_ id: Int, message: String) async throws {
        try await client.perform(.post, "issue/\(id)/comment", json: ["message": message])
    }
}

struct SeerrSearchPage: Decodable, Sendable {
    var page: Int?
    var totalPages: Int?
    var results: [SeerrSearchResult]

    enum CodingKeys: String, CodingKey { case page, totalPages, results }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = try c.decodeIfPresent(Int.self, forKey: .page)
        totalPages = try c.decodeIfPresent(Int.self, forKey: .totalPages)
        // Person and collection entries have a different shape; skip anything that doesn't decode.
        let raw = try c.decodeIfPresent([JSONValue].self, forKey: .results) ?? []
        results = raw.compactMap { try? $0.decode(SeerrSearchResult.self) }
    }
}

struct SeerrNewRequest: Encodable {
    var mediaType: String
    var mediaId: Int
    var seasons: [Int]?
    var is4k: Bool
}
