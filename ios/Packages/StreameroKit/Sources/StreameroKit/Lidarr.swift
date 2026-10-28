import Foundation

public struct MusicStatistics: Decodable, Sendable, Hashable {
    public var albumCount: Int?
    public var trackFileCount: Int?
    public var trackCount: Int?
    public var totalTrackCount: Int?
    public var sizeOnDisk: Double?
    public var percentOfTracks: Double?
}

public struct Artist: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var artistName: String
    public var overview: String?
    public var monitored: Bool?
    public var status: String?
    public var images: [ArrImage]?
    public var statistics: MusicStatistics?
    public var genres: [String]?
    public var path: String?
    public var foreignArtistId: String?

    enum CodingKeys: String, CodingKey { case id, artistName, overview, monitored, status, images, statistics, genres, path, foreignArtistId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        artistName = try c.decodeIfPresent(String.self, forKey: .artistName) ?? "Unknown artist"
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        monitored = try c.decodeIfPresent(Bool.self, forKey: .monitored)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        images = try c.decodeIfPresent([ArrImage].self, forKey: .images)
        statistics = try c.decodeIfPresent(MusicStatistics.self, forKey: .statistics)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        foreignArtistId = try c.decodeIfPresent(String.self, forKey: .foreignArtistId)
    }

    public var isInLibrary: Bool { id > 0 }
}

public struct Album: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var title: String
    public var releaseDate: Date?
    public var albumType: String?
    public var monitored: Bool?
    public var statistics: MusicStatistics?
    public var images: [ArrImage]?
    public var artistId: Int?
    public var artist: Artist?

    enum CodingKeys: String, CodingKey { case id, title, releaseDate, albumType, monitored, statistics, images, artistId, artist }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        releaseDate = try c.decodeIfPresent(Date.self, forKey: .releaseDate)
        albumType = try c.decodeIfPresent(String.self, forKey: .albumType)
        monitored = try c.decodeIfPresent(Bool.self, forKey: .monitored)
        statistics = try c.decodeIfPresent(MusicStatistics.self, forKey: .statistics)
        images = try c.decodeIfPresent([ArrImage].self, forKey: .images)
        artistId = try c.decodeIfPresent(Int.self, forKey: .artistId)
        artist = try c.decodeIfPresent(Artist.self, forKey: .artist)
    }
}

public struct MetadataProfile: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
}

public struct LidarrClient: ArrService {
    public let client: ServiceClient
    public init(client: ServiceClient) { self.client = client }

    public func artists() async throws -> [Artist] { try await client.get("artist") }
    public func albums(artistId: Int) async throws -> [Album] {
        try await client.get("album", query: [URLQueryItem(name: "artistId", value: String(artistId))])
    }
    public func metadataProfiles() async throws -> [MetadataProfile] { try await client.get("metadataprofile") }

    public func calendar(from start: Date, to end: Date) async throws -> [Album] {
        try await client.get("calendar", query: [
            URLQueryItem(name: "start", value: ISODay.string(start)), URLQueryItem(name: "end", value: ISODay.string(end)),
            URLQueryItem(name: "includeArtist", value: "true"),
        ])
    }

    public func queue(pageSize: Int = 100) async throws -> ArrPage<QueueItem> {
        try await client.get("queue", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "includeArtist", value: "true"), URLQueryItem(name: "includeAlbum", value: "true"),
        ])
    }

    public func missing(pageSize: Int = 50) async throws -> ArrPage<Album> {
        try await client.get("wanted/missing", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "includeArtist", value: "true"), URLQueryItem(name: "monitored", value: "true"),
        ])
    }

    public func history(pageSize: Int = 50) async throws -> ArrPage<HistoryRecord> {
        try await client.get("history", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: "date"), URLQueryItem(name: "sortDirection", value: "descending"),
            URLQueryItem(name: "includeArtist", value: "true"), URLQueryItem(name: "includeAlbum", value: "true"),
        ])
    }

    public func lookup(_ term: String) async throws -> [JSONValue] {
        try await client.get("artist/lookup", query: [URLQueryItem(name: "term", value: term)])
    }

    @discardableResult
    public func add(_ lookup: JSONValue, qualityProfileId: Int, metadataProfileId: Int, rootFolderPath: String, searchNow: Bool = true) async throws -> Artist {
        let body = ArrAdd.prepare(lookup, qualityProfileId: qualityProfileId, rootFolderPath: rootFolderPath, extra: [
            "metadataProfileId": JSONValue(metadataProfileId),
            "addOptions": .object(["monitor": .string("all"), "searchForMissingAlbums": .bool(searchNow)]),
        ])
        return try await client.send(.post, "artist", json: body)
    }

    public func setMonitored(artistId: Int, _ monitored: Bool) async throws {
        try await updateRaw("artist/\(artistId)") { $0["monitored"] = .bool(monitored) }
    }

    public func delete(artistId: Int, deleteFiles: Bool) async throws {
        try await client.perform(.delete, "artist/\(artistId)", query: [URLQueryItem(name: "deleteFiles", value: String(deleteFiles))])
    }

    public func searchArtist(_ id: Int) async throws { try await command("ArtistSearch", ["artistId": JSONValue(id)]) }
    public func searchAlbums(_ ids: [Int]) async throws { try await command("AlbumSearch", ["albumIds": .array(ids.map(JSONValue.init))]) }
}
