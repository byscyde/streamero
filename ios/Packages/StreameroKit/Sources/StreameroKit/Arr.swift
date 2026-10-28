import Foundation

// MARK: - Shared *arr models (Sonarr v3, Radarr v3, Lidarr v1, Prowlarr v1)

public struct ArrSystemStatus: Decodable, Sendable {
    public var appName: String?
    public var instanceName: String?
    public var version: String?
    public var startTime: Date?
    public var osName: String?
    public var isDocker: Bool?
}

public struct ArrHealth: Decodable, Sendable, Identifiable, Hashable {
    public var source: String?
    public var type: String
    public var message: String
    public var wikiUrl: String?
    public var id: String { "\(source ?? "")|\(message)" }
    public var severity: HealthSeverity { HealthSeverity(type) }
}

public enum HealthSeverity: Int, Sendable, Comparable {
    case ok, notice, warning, error
    public init(_ raw: String) {
        switch raw.lowercased() {
        case "error": self = .error
        case "warning": self = .warning
        case "notice": self = .notice
        default: self = .ok
        }
    }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct DiskSpace: Decodable, Sendable, Hashable {
    public var path: String?
    public var label: String?
    public var freeSpace: Double
    public var totalSpace: Double
    public var usedFraction: Double { totalSpace > 0 ? max(0, min(1, 1 - freeSpace / totalSpace)) : 0 }
}

public struct ArrImage: Decodable, Sendable, Hashable {
    public var coverType: String?
    public var url: String?
    public var remoteUrl: String?
}

extension Array where Element == ArrImage {
    /// Prefers the public remote image (TMDB/TVDB/fanart) so no API key is needed to load it.
    public func url(for type: String, base: URL? = nil) -> URL? {
        guard let image = first(where: { $0.coverType == type }) else { return nil }
        if let remote = image.remoteUrl, let url = URL(string: remote) { return url }
        if let path = image.url, let base { return URL(string: path, relativeTo: base)?.absoluteURL }
        return nil
    }
    public var poster: URL? { url(for: "poster") ?? url(for: "cover") }
    public var fanart: URL? { url(for: "fanart") ?? url(for: "banner") }
}

public struct QualityProfile: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String
}

public struct RootFolder: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var path: String
    public var freeSpace: Double?
}

public struct NamedQuality: Decodable, Sendable, Hashable {
    public struct Inner: Decodable, Sendable, Hashable { public var name: String? }
    public var quality: Inner?
    public var name: String? { quality?.name }
}

public struct ArrPage<T: Decodable & Sendable>: Decodable, Sendable {
    public var page: Int?
    public var pageSize: Int?
    public var totalRecords: Int
    public var records: [T]
}

public struct QueueStatusMessage: Decodable, Sendable, Hashable {
    public var title: String?
    public var messages: [String]?
}

public struct QueueItem: Decodable, Sendable, Identifiable {
    public var id: Int
    public var title: String?
    public var status: String?
    public var trackedDownloadStatus: String?
    public var trackedDownloadState: String?
    public var size: Double?
    public var sizeleft: Double?
    public var timeleft: String?
    public var estimatedCompletionTime: Date?
    public var downloadClient: String?
    public var `protocol`: String?
    public var indexer: String?
    public var errorMessage: String?
    public var statusMessages: [QueueStatusMessage]?
    public var quality: NamedQuality?
    public var series: Series?
    public var episode: Episode?
    public var movie: Movie?
    public var artist: Artist?
    public var album: Album?

    /// 0…1 download progress.
    public var progress: Double {
        guard let size, size > 0, let sizeleft else { return 0 }
        return max(0, min(1, 1 - sizeleft / size))
    }

    public var hasProblem: Bool {
        (trackedDownloadStatus?.lowercased()).map { $0 == "warning" || $0 == "error" } ?? false
            || status?.lowercased() == "failed" || errorMessage != nil
    }

    public var problemText: String? {
        errorMessage ?? statusMessages?.flatMap { $0.messages ?? [] }.first
    }
}

public struct HistoryRecord: Decodable, Sendable, Identifiable {
    public var id: Int
    public var eventType: String?
    public var sourceTitle: String?
    public var date: Date?
    public var quality: NamedQuality?
    public var series: Series?
    public var episode: Episode?
    public var movie: Movie?
    public var artist: Artist?
    public var album: Album?
}

public struct CommandResponse: Decodable, Sendable {
    public var id: Int?
    public var name: String?
    public var status: String?
}

// MARK: - Shared client behaviour

public protocol ArrService: Sendable {
    var client: ServiceClient { get }
}

extension ArrService {
    public func systemStatus() async throws -> ArrSystemStatus { try await client.get("system/status") }
    public func health() async throws -> [ArrHealth] { try await client.get("health") }
    public func diskSpace() async throws -> [DiskSpace] { try await client.get("diskspace") }
    public func qualityProfiles() async throws -> [QualityProfile] { try await client.get("qualityprofile") }
    public func rootFolders() async throws -> [RootFolder] { try await client.get("rootfolder") }

    /// Runs a named command (e.g. "RssSync", "RefreshMonitoredDownloads") with extra fields.
    @discardableResult
    public func command(_ name: String, _ fields: [String: JSONValue] = [:]) async throws -> CommandResponse {
        var body = fields
        body["name"] = .string(name)
        return try await client.send(.post, "command", json: body)
    }

    /// Removes a download from the queue; optionally from the download client and blocklisted.
    public func removeFromQueue(_ id: Int, removeFromClient: Bool = true, blocklist: Bool = false) async throws {
        try await client.perform(.delete, "queue/\(id)", query: [
            URLQueryItem(name: "removeFromClient", value: String(removeFromClient)),
            URLQueryItem(name: "blocklist", value: String(blocklist)),
        ])
    }

    /// Fetches a resource as raw JSON, edits it and PUTs it back, so fields the app doesn't model survive.
    public func updateRaw(_ path: String, _ edit: (inout JSONValue) -> Void) async throws {
        var resource: JSONValue = try await client.get(path)
        edit(&resource)
        try await client.perform(.put, path, json: resource)
    }
}

/// Prepares a lookup result for POSTing as a new item.
public enum ArrAdd {
    public static func prepare(_ lookup: JSONValue, qualityProfileId: Int, rootFolderPath: String, monitored: Bool = true, extra: [String: JSONValue]) -> JSONValue {
        var body = lookup
        body["id"] = nil
        body["qualityProfileId"] = JSONValue(qualityProfileId)
        body["rootFolderPath"] = .string(rootFolderPath)
        body["monitored"] = .bool(monitored)
        for (key, value) in extra { body[key] = value }
        return body
    }
}
