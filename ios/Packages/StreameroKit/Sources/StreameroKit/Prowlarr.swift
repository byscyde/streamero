import Foundation

public struct Indexer: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var enable: Bool
    public var `protocol`: String?
    public var privacy: String?
    public var priority: Int?
    public var implementationName: String?

    enum CodingKeys: String, CodingKey { case id, name, enable, `protocol`, privacy, priority, implementationName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Indexer \(id)"
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable) ?? false
        `protocol` = try c.decodeIfPresent(String.self, forKey: .protocol)
        privacy = try c.decodeIfPresent(String.self, forKey: .privacy)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        implementationName = try c.decodeIfPresent(String.self, forKey: .implementationName)
    }
}

public struct IndexerStatus: Decodable, Sendable, Hashable {
    public var indexerId: Int
    public var disabledTill: Date?
    public var mostRecentFailure: Date?
}

public struct IndexerStats: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Hashable, Identifiable {
        public var indexerId: Int
        public var indexerName: String?
        public var averageResponseTime: Double?
        public var numberOfQueries: Int?
        public var numberOfGrabs: Int?
        public var numberOfFailedQueries: Int?
        public var numberOfFailedGrabs: Int?
        public var id: Int { indexerId }
    }
    public var indexers: [Entry]?
}

public struct ReleaseResult: Decodable, Sendable, Identifiable, Hashable {
    public struct Category: Decodable, Sendable, Hashable { public var id: Int?; public var name: String? }
    public var guid: String
    public var title: String?
    public var size: Double?
    public var indexer: String?
    public var indexerId: Int
    public var publishDate: Date?
    public var seeders: Int?
    public var leechers: Int?
    public var grabs: Int?
    public var `protocol`: String?
    public var infoUrl: String?
    public var categories: [Category]?
    public var id: String { "\(indexerId)|\(guid)" }
}

public struct ProwlarrApplication: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String?
    public var implementation: String?
    public var syncLevel: String?
}

public struct ProwlarrClient: ArrService {
    public let client: ServiceClient
    public init(client: ServiceClient) { self.client = client }

    public func indexers() async throws -> [Indexer] { try await client.get("indexer") }
    public func indexerStatuses() async throws -> [IndexerStatus] { try await client.get("indexerstatus") }
    public func stats() async throws -> IndexerStats { try await client.get("indexerstats") }
    public func applications() async throws -> [ProwlarrApplication] { try await client.get("applications") }

    public func setEnabled(indexerId: Int, _ enabled: Bool) async throws {
        try await updateRaw("indexer/\(indexerId)") { $0["enable"] = .bool(enabled) }
    }

    /// Tests one indexer with its stored settings; throws with the indexer's error message on failure.
    public func test(indexerId: Int) async throws {
        let indexer: JSONValue = try await client.get("indexer/\(indexerId)")
        try await client.perform(.post, "indexer/test", json: indexer)
    }

    public func testAll() async throws { try await client.perform(.post, "indexer/testall") }

    public func search(_ query: String, indexerIds: [Int] = [], limit: Int = 100) async throws -> [ReleaseResult] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "type", value: "search"), URLQueryItem(name: "limit", value: String(limit))]
        items += indexerIds.map { URLQueryItem(name: "indexerIds", value: String($0)) }
        return try await client.get("search", query: items)
    }

    /// Sends a release to the configured download client.
    public func grab(_ release: ReleaseResult) async throws {
        try await client.perform(.post, "search", json: ["guid": JSONValue.string(release.guid), "indexerId": JSONValue(release.indexerId)])
    }

    public func syncApplications() async throws { try await command("ApplicationIndexerSync") }
}
