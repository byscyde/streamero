import Foundation

public struct Movie: Decodable, Sendable, Identifiable, Hashable {
    public struct MovieFile: Decodable, Sendable, Hashable {
        public var size: Double?
        public var quality: NamedQuality?
        public var relativePath: String?
    }

    /// 0 for lookup results that aren't in the library yet.
    public var id: Int
    public var title: String
    public var year: Int?
    public var overview: String?
    public var monitored: Bool?
    public var hasFile: Bool?
    public var status: String?
    public var isAvailable: Bool?
    public var sizeOnDisk: Double?
    public var images: [ArrImage]?
    public var runtime: Int?
    public var studio: String?
    public var genres: [String]?
    public var tmdbId: Int?
    public var imdbId: String?
    public var inCinemas: Date?
    public var digitalRelease: Date?
    public var physicalRelease: Date?
    public var added: Date?
    public var path: String?
    public var qualityProfileId: Int?
    public var movieFile: MovieFile?

    enum CodingKeys: String, CodingKey {
        case id, title, year, overview, monitored, hasFile, status, isAvailable, sizeOnDisk, images, runtime, studio, genres, tmdbId, imdbId, inCinemas, digitalRelease, physicalRelease, added, path, qualityProfileId, movieFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        monitored = try c.decodeIfPresent(Bool.self, forKey: .monitored)
        hasFile = try c.decodeIfPresent(Bool.self, forKey: .hasFile)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        isAvailable = try c.decodeIfPresent(Bool.self, forKey: .isAvailable)
        sizeOnDisk = try c.decodeIfPresent(Double.self, forKey: .sizeOnDisk)
        images = try c.decodeIfPresent([ArrImage].self, forKey: .images)
        runtime = try c.decodeIfPresent(Int.self, forKey: .runtime)
        studio = try c.decodeIfPresent(String.self, forKey: .studio)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId)
        imdbId = try c.decodeIfPresent(String.self, forKey: .imdbId)
        inCinemas = try c.decodeIfPresent(Date.self, forKey: .inCinemas)
        digitalRelease = try c.decodeIfPresent(Date.self, forKey: .digitalRelease)
        physicalRelease = try c.decodeIfPresent(Date.self, forKey: .physicalRelease)
        added = try c.decodeIfPresent(Date.self, forKey: .added)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        qualityProfileId = try c.decodeIfPresent(Int.self, forKey: .qualityProfileId)
        movieFile = try c.decodeIfPresent(MovieFile.self, forKey: .movieFile)
    }

    public var isInLibrary: Bool { id > 0 }
    /// Earliest upcoming release relevant for the calendar.
    public var nextRelease: Date? {
        [inCinemas, digitalRelease, physicalRelease].compactMap { $0 }.filter { $0 > Date().addingTimeInterval(-86_400) }.min()
    }
}

public struct RadarrClient: ArrService {
    public let client: ServiceClient
    public init(client: ServiceClient) { self.client = client }

    public func movies() async throws -> [Movie] { try await client.get("movie") }
    public func movie(_ id: Int) async throws -> Movie { try await client.get("movie/\(id)") }

    public func calendar(from start: Date, to end: Date) async throws -> [Movie] {
        try await client.get("calendar", query: [
            URLQueryItem(name: "start", value: ISODay.string(start)), URLQueryItem(name: "end", value: ISODay.string(end)),
        ])
    }

    public func queue(pageSize: Int = 100) async throws -> ArrPage<QueueItem> {
        try await client.get("queue", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "includeMovie", value: "true"),
        ])
    }

    public func missing(pageSize: Int = 50) async throws -> ArrPage<Movie> {
        try await client.get("wanted/missing", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "monitored", value: "true"),
        ])
    }

    public func history(pageSize: Int = 50) async throws -> ArrPage<HistoryRecord> {
        try await client.get("history", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: "date"), URLQueryItem(name: "sortDirection", value: "descending"),
            URLQueryItem(name: "includeMovie", value: "true"),
        ])
    }

    public func lookup(_ term: String) async throws -> [JSONValue] {
        try await client.get("movie/lookup", query: [URLQueryItem(name: "term", value: term)])
    }

    @discardableResult
    public func add(_ lookup: JSONValue, qualityProfileId: Int, rootFolderPath: String, minimumAvailability: String = "released", searchNow: Bool = true) async throws -> Movie {
        let body = ArrAdd.prepare(lookup, qualityProfileId: qualityProfileId, rootFolderPath: rootFolderPath, extra: [
            "minimumAvailability": .string(minimumAvailability),
            "addOptions": .object(["searchForMovie": .bool(searchNow), "monitor": .string("movieOnly")]),
        ])
        return try await client.send(.post, "movie", json: body)
    }

    public func setMonitored(movieId: Int, _ monitored: Bool) async throws {
        try await updateRaw("movie/\(movieId)") { $0["monitored"] = .bool(monitored) }
    }

    public func delete(movieId: Int, deleteFiles: Bool, addExclusion: Bool = false) async throws {
        try await client.perform(.delete, "movie/\(movieId)", query: [
            URLQueryItem(name: "deleteFiles", value: String(deleteFiles)),
            URLQueryItem(name: "addImportExclusion", value: String(addExclusion)),
        ])
    }

    public func search(movieIds: [Int]) async throws { try await command("MoviesSearch", ["movieIds": .array(movieIds.map(JSONValue.init))]) }
    public func refresh(movieIds: [Int]) async throws { try await command("RefreshMovie", ["movieIds": .array(movieIds.map(JSONValue.init))]) }
    public func searchAllMissing() async throws { try await command("MissingMoviesSearch") }
}
