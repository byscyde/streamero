import Foundation

// System pages shared by Sonarr, Radarr, Lidarr and Prowlarr: tasks, backups, updates, logs, tags,
// root folders, quality profiles, blocklist, interactive search, restart/shutdown.

public struct ArrTask: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String?
    public var taskName: String?
    public var interval: Int?
    public var lastExecution: Date?
    public var nextExecution: Date?
    public var lastDuration: String?
}

public struct ArrBackup: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String?
    public var type: String?
    public var size: Double?
    public var time: Date?
}

public struct ArrUpdate: Decodable, Sendable, Identifiable, Hashable {
    public struct Changes: Decodable, Sendable, Hashable {
        public var new: [String]?
        public var fixed: [String]?
    }
    public var version: String
    public var branch: String?
    public var releaseDate: Date?
    public var installed: Bool?
    public var installable: Bool?
    public var latest: Bool?
    public var changes: Changes?
    public var id: String { version }
}

public struct ArrLogEntry: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var time: Date?
    public var level: String?
    public var logger: String?
    public var message: String?
    public var exception: String?
}

public struct ArrTag: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var label: String
}

public struct BlocklistItem: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var sourceTitle: String?
    public var date: Date?
    public var message: String?
    public var indexer: String?
    public var `protocol`: String?
    public var quality: NamedQuality?
}

/// A quality profile with its allowed qualities (read view of the full profile).
public struct QualityProfileDetail: Sendable, Identifiable, Hashable {
    public var raw: JSONValue
    public var id: Int { raw["id"]?.intValue ?? 0 }
    public var name: String { raw["name"]?.stringValue ?? "Profile" }
    public var upgradeAllowed: Bool { raw["upgradeAllowed"]?.boolValue ?? false }
    public var minFormatScore: Int? { raw["minFormatScore"]?.intValue }
    public var cutoffFormatScore: Int? { raw["cutoffFormatScore"]?.intValue }

    /// Allowed quality names, best first (groups are flattened into "Group (a, b)").
    public var allowed: [String] {
        (raw["items"]?.arrayValue ?? []).reversed().compactMap { item in
            guard item["allowed"]?.boolValue == true else { return nil }
            if let quality = item["quality"]?["name"]?.stringValue { return quality }
            let members = (item["items"]?.arrayValue ?? []).compactMap { $0["quality"]?["name"]?.stringValue }
            return "\(item["name"]?.stringValue ?? "Group") (\(members.joined(separator: ", ")))"
        }
    }

    /// Name of the cutoff quality or group.
    public var cutoff: String? {
        guard let cutoffId = raw["cutoff"]?.intValue else { return nil }
        for item in raw["items"]?.arrayValue ?? [] {
            if item["quality"]?["id"]?.intValue == cutoffId { return item["quality"]?["name"]?.stringValue }
            if item["id"]?.intValue == cutoffId { return item["name"]?.stringValue }
        }
        return nil
    }
}

/// A release found by interactive search, with the reasons the app would or wouldn't take it.
public struct ArrRelease: Sendable, Identifiable, Hashable {
    public var raw: JSONValue
    public var id: String { "\(indexerId)|\(guid)" }
    public var guid: String { raw["guid"]?.stringValue ?? "" }
    public var indexerId: Int { raw["indexerId"]?.intValue ?? 0 }
    public var title: String { raw["title"]?.stringValue ?? "Release" }
    public var indexer: String? { raw["indexer"]?.stringValue }
    public var size: Double? { if case .number(let n)? = raw["size"] { n } else { nil } }
    public var quality: String? { raw["quality"]?["quality"]?["name"]?.stringValue }
    public var ageHours: Double? { if case .number(let n)? = raw["ageHours"] { n } else { nil } }
    public var seeders: Int? { raw["seeders"]?.intValue }
    public var leechers: Int? { raw["leechers"]?.intValue }
    public var `protocol`: String? { raw["protocol"]?.stringValue }
    public var approved: Bool { raw["approved"]?.boolValue ?? false }
    public var customFormatScore: Int? { raw["customFormatScore"]?.intValue }
    public var languages: [String] { (raw["languages"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue } }

    /// Rejections are plain strings in older versions and {reason, type} objects in newer ones.
    public var rejections: [String] {
        (raw["rejections"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["reason"]?.stringValue }
    }

    public var ageText: String? {
        guard let hours = ageHours else { return nil }
        if hours < 1 { return "\(Int(hours * 60))m" }
        if hours < 48 { return "\(Int(hours))h" }
        return "\(Int(hours / 24))d"
    }
}

/// What to search releases for.
public enum ReleaseTarget: Sendable, Hashable {
    case episode(Int)
    case season(seriesId: Int, season: Int)
    case movie(Int)
    case album(Int)

    var query: [URLQueryItem] {
        switch self {
        case .episode(let id): [URLQueryItem(name: "episodeId", value: String(id))]
        case .season(let seriesId, let season): [URLQueryItem(name: "seriesId", value: String(seriesId)), URLQueryItem(name: "seasonNumber", value: String(season))]
        case .movie(let id): [URLQueryItem(name: "movieId", value: String(id))]
        case .album(let id): [URLQueryItem(name: "albumId", value: String(id))]
        }
    }
}

extension ArrService {
    public func tasks() async throws -> [ArrTask] { try await client.get("system/task") }
    /// Scheduled tasks run as commands named after `taskName`.
    public func run(_ task: ArrTask) async throws {
        guard let name = task.taskName else { throw ServiceError.decoding("task has no taskName") }
        try await command(name)
    }

    public func backups() async throws -> [ArrBackup] { try await client.get("system/backup") }
    public func createBackup() async throws { try await command("Backup") }
    public func deleteBackup(_ id: Int) async throws { try await client.perform(.delete, "system/backup/\(id)") }

    public func updates() async throws -> [ArrUpdate] { try await client.get("update") }
    public func installUpdate() async throws { try await command("ApplicationUpdate") }

    public func logs(pageSize: Int = 100, level: String? = nil) async throws -> ArrPage<ArrLogEntry> {
        var query = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
                     URLQueryItem(name: "sortKey", value: "time"), URLQueryItem(name: "sortDirection", value: "descending")]
        if let level { query.append(URLQueryItem(name: "level", value: level)) }
        return try await client.get("log", query: query)
    }

    public func restartApp() async throws { try await client.perform(.post, "system/restart") }
    public func shutdownApp() async throws { try await client.perform(.post, "system/shutdown") }

    public func tags() async throws -> [ArrTag] { try await client.get("tag") }
    @discardableResult
    public func createTag(_ label: String) async throws -> ArrTag { try await client.send(.post, "tag", json: ["label": label]) }
    public func deleteTag(_ id: Int) async throws { try await client.perform(.delete, "tag/\(id)") }

    public func addRootFolder(_ path: String) async throws { try await client.perform(.post, "rootfolder", json: ["path": path]) }
    public func deleteRootFolder(_ id: Int) async throws { try await client.perform(.delete, "rootfolder/\(id)") }

    public func qualityProfileDetails() async throws -> [QualityProfileDetail] {
        let list: [JSONValue] = try await client.get("qualityprofile")
        return list.map(QualityProfileDetail.init)
    }

    public func setUpgradeAllowed(profileId: Int, _ allowed: Bool) async throws {
        try await updateRaw("qualityprofile/\(profileId)") { $0["upgradeAllowed"] = .bool(allowed) }
    }

    public func blocklist(pageSize: Int = 100) async throws -> ArrPage<BlocklistItem> {
        try await client.get("blocklist", query: [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(pageSize)),
                                                  URLQueryItem(name: "sortKey", value: "date"), URLQueryItem(name: "sortDirection", value: "descending")])
    }
    public func removeFromBlocklist(_ id: Int) async throws { try await client.perform(.delete, "blocklist/\(id)") }

    /// Interactive search: asks every indexer now and returns releases with approval decisions.
    public func releases(for target: ReleaseTarget) async throws -> [ArrRelease] {
        var c = client
        c.timeout = 120
        let list: [JSONValue] = try await c.get("release", query: target.query)
        return list.map(ArrRelease.init)
    }

    /// Grabs a release found by interactive search (sends it to the download client).
    public func grab(_ release: ArrRelease) async throws {
        try await client.perform(.post, "release", json: ["guid": JSONValue.string(release.guid), "indexerId": JSONValue(release.indexerId)])
    }
}

/// Fields a user edits on a library item; applied onto the raw resource so nothing else changes.
public struct ItemEdit: Sendable, Hashable {
    public var monitored: Bool
    public var qualityProfileId: Int?
    public var metadataProfileId: Int?
    public var tags: [Int]
    public var minimumAvailability: String?
    public var seriesType: String?
    public var seasonFolder: Bool?
    public var monitoredSeasons: [Int: Bool]

    public init(raw: JSONValue) {
        monitored = raw["monitored"]?.boolValue ?? false
        qualityProfileId = raw["qualityProfileId"]?.intValue
        metadataProfileId = raw["metadataProfileId"]?.intValue
        tags = (raw["tags"]?.arrayValue ?? []).compactMap(\.intValue)
        minimumAvailability = raw["minimumAvailability"]?.stringValue
        seriesType = raw["seriesType"]?.stringValue
        seasonFolder = raw["seasonFolder"]?.boolValue
        var seasons: [Int: Bool] = [:]
        for season in raw["seasons"]?.arrayValue ?? [] {
            if let number = season["seasonNumber"]?.intValue { seasons[number] = season["monitored"]?.boolValue ?? false }
        }
        monitoredSeasons = seasons
    }

    public func apply(to raw: inout JSONValue) {
        raw["monitored"] = .bool(monitored)
        if let qualityProfileId { raw["qualityProfileId"] = JSONValue(qualityProfileId) }
        if let metadataProfileId { raw["metadataProfileId"] = JSONValue(metadataProfileId) }
        raw["tags"] = .array(tags.map(JSONValue.init))
        if let minimumAvailability { raw["minimumAvailability"] = .string(minimumAvailability) }
        if let seriesType { raw["seriesType"] = .string(seriesType) }
        if let seasonFolder { raw["seasonFolder"] = .bool(seasonFolder) }
        if var seasons = raw["seasons"]?.arrayValue, !monitoredSeasons.isEmpty {
            for index in seasons.indices {
                if let number = seasons[index]["seasonNumber"]?.intValue, let flag = monitoredSeasons[number] { seasons[index]["monitored"] = .bool(flag) }
            }
            raw["seasons"] = .array(seasons)
        }
    }
}

extension ArrService {
    /// Loads an item (e.g. "movie/3", "series/12", "artist/5") for editing.
    public func editableItem(_ path: String) async throws -> JSONValue { try await client.get(path) }

    public func saveItem(_ path: String, raw: JSONValue, edit: ItemEdit) async throws {
        var body = raw
        edit.apply(to: &body)
        try await client.perform(.put, path, json: body)
    }
}
