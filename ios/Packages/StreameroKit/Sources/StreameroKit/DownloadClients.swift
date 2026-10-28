import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - qBittorrent (Web UI API v2)

public struct Torrent: Decodable, Sendable, Identifiable, Hashable {
    public var hash: String
    public var name: String
    public var size: Double?
    public var progress: Double?
    public var dlspeed: Double?
    public var upspeed: Double?
    public var eta: Int?
    public var state: String?
    public var category: String?
    public var ratio: Double?
    public var addedOn: Double?
    public var numSeeds: Int?
    public var numLeechs: Int?
    public var savePath: String?
    public var id: String { hash }

    enum CodingKeys: String, CodingKey {
        case hash, name, size, progress, dlspeed, upspeed, eta, state, category, ratio
        case addedOn = "added_on", numSeeds = "num_seeds", numLeechs = "num_leechs", savePath = "save_path"
    }

    public var isPaused: Bool { ["pausedDL", "pausedUP", "stoppedDL", "stoppedUP"].contains(state ?? "") }
    public var isErrored: Bool { ["error", "missingFiles"].contains(state ?? "") }
    public var isComplete: Bool { (progress ?? 0) >= 1 }

    public var stateTitle: String {
        switch state ?? "" {
        case "downloading", "forcedDL": "Downloading"
        case "metaDL", "forcedMetaDL": "Fetching metadata"
        case "stalledDL": "Stalled"
        case "uploading", "forcedUP": "Seeding"
        case "stalledUP": "Seeding (idle)"
        case "pausedDL", "stoppedDL": "Paused"
        case "pausedUP", "stoppedUP": "Completed"
        case "queuedDL", "queuedUP": "Queued"
        case "checkingDL", "checkingUP", "checkingResumeData": "Checking"
        case "moving": "Moving"
        case "error": "Error"
        case "missingFiles": "Missing files"
        default: (state ?? "Unknown").capitalized
        }
    }

    /// Seconds → "2h 5m"; qBittorrent uses 8640000 for "infinite".
    public var etaText: String? {
        guard let eta, eta > 0, eta < 8_640_000 else { return nil }
        let h = eta / 3600, m = (eta % 3600) / 60
        return h > 24 ? "\(h / 24)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(max(1, m))m"
    }
}

public struct TransferInfo: Decodable, Sendable {
    public var dlInfoSpeed: Double?
    public var upInfoSpeed: Double?
    public var dlRateLimit: Double?
    public var upRateLimit: Double?
    public var connectionStatus: String?

    enum CodingKeys: String, CodingKey {
        case dlInfoSpeed = "dl_info_speed", upInfoSpeed = "up_info_speed", dlRateLimit = "dl_rate_limit", upRateLimit = "up_rate_limit", connectionStatus = "connection_status"
    }
}

public enum TorrentFilter: String, CaseIterable, Sendable, Identifiable {
    case all, downloading, seeding, completed, paused, errored
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct QBittorrentClient: Sendable {
    public let client: ServiceClient
    public let username: String
    public let password: String

    public init(client: ServiceClient, username: String, password: String) {
        self.client = client
        self.username = username
        self.password = password
    }

    /// Signs in; the session cookie is kept by URLSession for the following calls.
    public func login() async throws {
        let body = Form.encode(["username": username, "password": password])
        let data = try await client.data(.post, "auth/login", body: body, contentType: Form.contentType)
        let text = String(decoding: data, as: UTF8.self)
        if text.lowercased().hasPrefix("fails") { throw ServiceError.unauthorized }
    }

    /// Runs a call, signing in once when the session is missing or expired (403).
    private func authed<T>(_ call: () async throws -> T) async throws -> T {
        do { return try await call() } catch ServiceError.unauthorized {
            try await login()
            return try await call()
        }
    }

    public func version() async throws -> String {
        try await authed { String(decoding: try await client.data(.get, "app/version"), as: UTF8.self) }
    }

    public func transferInfo() async throws -> TransferInfo { try await authed { try await client.get("transfer/info") } }

    public func torrents(filter: TorrentFilter = .all) async throws -> [Torrent] {
        let query = [URLQueryItem(name: "filter", value: filter.rawValue), URLQueryItem(name: "sort", value: "added_on"), URLQueryItem(name: "reverse", value: "true")]
        return try await authed { try await client.get("torrents/info", query: query) }
    }

    private func post(_ path: String, _ fields: [String: String]) async throws {
        try await authed { _ = try await client.data(.post, path, body: Form.encode(fields), contentType: Form.contentType) }
    }

    /// qBittorrent 5 renamed pause/resume to stop/start; try the new name first.
    public func pause(_ hashes: [String]) async throws {
        do { try await post("torrents/stop", ["hashes": hashes.joined(separator: "|")]) } catch ServiceError.notFound {
            try await post("torrents/pause", ["hashes": hashes.joined(separator: "|")])
        }
    }

    public func resume(_ hashes: [String]) async throws {
        do { try await post("torrents/start", ["hashes": hashes.joined(separator: "|")]) } catch ServiceError.notFound {
            try await post("torrents/resume", ["hashes": hashes.joined(separator: "|")])
        }
    }

    public func delete(_ hashes: [String], deleteFiles: Bool) async throws {
        try await post("torrents/delete", ["hashes": hashes.joined(separator: "|"), "deleteFiles": String(deleteFiles)])
    }

    public func recheck(_ hashes: [String]) async throws { try await post("torrents/recheck", ["hashes": hashes.joined(separator: "|")]) }
    public func reannounce(_ hashes: [String]) async throws { try await post("torrents/reannounce", ["hashes": hashes.joined(separator: "|")]) }

    public func add(urls: String, category: String? = nil) async throws {
        var fields = ["urls": urls]
        if let category, !category.isEmpty { fields["category"] = category }
        try await post("torrents/add", fields)
    }

    public func alternativeSpeedLimitsEnabled() async throws -> Bool {
        try await authed { String(decoding: try await client.data(.get, "transfer/speedLimitsMode"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1" }
    }

    public func toggleAlternativeSpeedLimits() async throws { try await post("transfer/toggleSpeedLimitsMode", [:]) }
}

/// application/x-www-form-urlencoded bodies.
public enum Form {
    public static let contentType = "application/x-www-form-urlencoded"
    public static func encode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - SABnzbd

public struct SabQueue: Decodable, Sendable {
    public struct Slot: Decodable, Sendable, Identifiable, Hashable {
        public var nzoId: String
        public var filename: String?
        public var percentage: String?
        public var mb: String?
        public var mbleft: String?
        public var timeleft: String?
        public var status: String?
        public var cat: String?
        public var id: String { nzoId }
        public var progress: Double { (Double(percentage ?? "0") ?? 0) / 100 }
        enum CodingKeys: String, CodingKey { case nzoId = "nzo_id", filename, percentage, mb, mbleft, timeleft, status, cat }
    }
    public var status: String?
    public var paused: Bool?
    public var speed: String?
    public var kbpersec: String?
    public var sizeleft: String?
    public var timeleft: String?
    public var speedlimit: String?
    public var slots: [Slot]
}

public struct SabHistory: Decodable, Sendable {
    public struct Slot: Decodable, Sendable, Identifiable, Hashable {
        public var nzoId: String
        public var name: String?
        public var status: String?
        public var completed: Double?
        public var bytes: Double?
        public var failMessage: String?
        public var category: String?
        public var id: String { nzoId }
        enum CodingKeys: String, CodingKey { case nzoId = "nzo_id", name, status, completed, bytes, failMessage = "fail_message", category }
    }
    public var slots: [Slot]
}

public struct SabnzbdClient: Sendable {
    public let client: ServiceClient
    public init(client: ServiceClient) { self.client = client }

    private struct QueueWrapper: Decodable { var queue: SabQueue }
    private struct HistoryWrapper: Decodable { var history: SabHistory }
    private struct VersionWrapper: Decodable { var version: String }

    @discardableResult
    private func call(_ mode: String, _ extra: [URLQueryItem] = []) async throws -> Data {
        let data = try await client.data(.get, "", query: [URLQueryItem(name: "mode", value: mode)] + extra)
        // SABnzbd answers 200 with {"status": false, "error": "API Key Incorrect"} on auth errors.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["status"] as? Bool == false {
            let message = json["error"] as? String
            if message?.lowercased().contains("api key") == true { throw ServiceError.unauthorized }
            throw ServiceError.http(status: 200, message: message)
        }
        return data
    }

    public func version() async throws -> String { try ServiceClient.decode(VersionWrapper.self, from: try await call("version")).version }
    public func queue() async throws -> SabQueue { try ServiceClient.decode(QueueWrapper.self, from: try await call("queue")).queue }
    public func history(limit: Int = 50) async throws -> SabHistory {
        try ServiceClient.decode(HistoryWrapper.self, from: try await call("history", [URLQueryItem(name: "limit", value: String(limit))])).history
    }

    public func pauseAll() async throws { try await call("pause") }
    public func resumeAll() async throws { try await call("resume") }
    public func pause(_ id: String) async throws { try await call("queue", [URLQueryItem(name: "name", value: "pause"), URLQueryItem(name: "value", value: id)]) }
    public func resume(_ id: String) async throws { try await call("queue", [URLQueryItem(name: "name", value: "resume"), URLQueryItem(name: "value", value: id)]) }
    public func delete(_ id: String, deleteFiles: Bool = true) async throws {
        try await call("queue", [URLQueryItem(name: "name", value: "delete"), URLQueryItem(name: "value", value: id), URLQueryItem(name: "del_files", value: deleteFiles ? "1" : "0")])
    }
    public func deleteHistory(_ id: String) async throws {
        try await call("history", [URLQueryItem(name: "name", value: "delete"), URLQueryItem(name: "value", value: id)])
    }
    public func retry(_ id: String) async throws { try await call("retry", [URLQueryItem(name: "value", value: id)]) }
    /// Speed limit as a percentage of the configured maximum (100 = no limit).
    public func setSpeedLimit(percent: Int) async throws {
        try await call("config", [URLQueryItem(name: "name", value: "speedlimit"), URLQueryItem(name: "value", value: String(percent))])
    }
    public func addURL(_ url: String) async throws { try await call("addurl", [URLQueryItem(name: "name", value: url)]) }
}
