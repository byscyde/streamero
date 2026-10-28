import Foundation

// Jellyfin 10.8+ REST API. Keys are PascalCase.

public struct JellyfinSystemInfo: Decodable, Sendable {
    public var serverName: String?
    public var version: String?
    public var operatingSystemDisplayName: String?
    public var hasPendingRestart: Bool?
    public var hasUpdateAvailable: Bool?
    public var id: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName", version = "Version", operatingSystemDisplayName = "OperatingSystemDisplayName"
        case hasPendingRestart = "HasPendingRestart", hasUpdateAvailable = "HasUpdateAvailable", id = "Id"
    }
}

public struct JellyfinItem: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String?
    public var type: String?
    public var seriesName: String?
    public var albumArtist: String?
    public var productionYear: Int?
    public var indexNumber: Int?
    public var parentIndexNumber: Int?
    public var runTimeTicks: Int64?
    public var dateCreated: Date?
    public var imageTags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", seriesName = "SeriesName", albumArtist = "AlbumArtist", productionYear = "ProductionYear"
        case indexNumber = "IndexNumber", parentIndexNumber = "ParentIndexNumber", runTimeTicks = "RunTimeTicks", dateCreated = "DateCreated", imageTags = "ImageTags"
    }

    /// "Show — S01E02 · Episode" / "Movie (2024)" / "Album — Artist"
    public var displayTitle: String {
        let base = name ?? "Unknown"
        if let seriesName {
            let code = (parentIndexNumber.map { String(format: "S%02d", $0) } ?? "") + (indexNumber.map { String(format: "E%02d", $0) } ?? "")
            return code.isEmpty ? "\(seriesName) — \(base)" : "\(seriesName) — \(code) · \(base)"
        }
        if let albumArtist { return "\(base) — \(albumArtist)" }
        if let productionYear { return "\(base) (\(productionYear))" }
        return base
    }

    public var hasPrimaryImage: Bool { imageTags?["Primary"] != nil }
}

public struct JellyfinSession: Decodable, Sendable, Identifiable, Hashable {
    public struct PlayState: Decodable, Sendable, Hashable {
        public var positionTicks: Int64?
        public var isPaused: Bool?
        public var playMethod: String?
        enum CodingKeys: String, CodingKey { case positionTicks = "PositionTicks", isPaused = "IsPaused", playMethod = "PlayMethod" }
    }
    public struct Transcoding: Decodable, Sendable, Hashable {
        public var videoCodec: String?
        public var audioCodec: String?
        public var bitrate: Int?
        public var isVideoDirect: Bool?
        public var isAudioDirect: Bool?
        public var completionPercentage: Double?
        public var transcodeReasons: [String]?
        enum CodingKeys: String, CodingKey {
            case videoCodec = "VideoCodec", audioCodec = "AudioCodec", bitrate = "Bitrate", isVideoDirect = "IsVideoDirect"
            case isAudioDirect = "IsAudioDirect", completionPercentage = "CompletionPercentage", transcodeReasons = "TranscodeReasons"
        }
    }

    public var id: String
    public var userName: String?
    public var userId: String?
    public var client: String?
    public var deviceName: String?
    public var applicationVersion: String?
    public var remoteEndPoint: String?
    public var lastActivityDate: Date?
    public var nowPlayingItem: JellyfinItem?
    public var playState: PlayState?
    public var transcodingInfo: Transcoding?
    public var supportsRemoteControl: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id", userName = "UserName", userId = "UserId", client = "Client", deviceName = "DeviceName", applicationVersion = "ApplicationVersion"
        case remoteEndPoint = "RemoteEndPoint", lastActivityDate = "LastActivityDate", nowPlayingItem = "NowPlayingItem", playState = "PlayState"
        case transcodingInfo = "TranscodingInfo", supportsRemoteControl = "SupportsRemoteControl"
    }

    public var isPlaying: Bool { nowPlayingItem != nil }
    public var isTranscoding: Bool { transcodingInfo.map { $0.isVideoDirect == false || $0.isAudioDirect == false } ?? false }

    /// 0…1 playback position.
    public var progress: Double {
        guard let total = nowPlayingItem?.runTimeTicks, total > 0, let position = playState?.positionTicks else { return 0 }
        return max(0, min(1, Double(position) / Double(total)))
    }
}

public struct VirtualFolder: Decodable, Sendable, Identifiable, Hashable {
    public var name: String
    public var collectionType: String?
    public var itemId: String?
    public var locations: [String]?
    public var refreshStatus: String?
    public var id: String { itemId ?? name }

    enum CodingKeys: String, CodingKey { case name = "Name", collectionType = "CollectionType", itemId = "ItemId", locations = "Locations", refreshStatus = "RefreshStatus" }
}

public struct ItemCounts: Decodable, Sendable {
    public var movieCount: Int?
    public var seriesCount: Int?
    public var episodeCount: Int?
    public var albumCount: Int?
    public var songCount: Int?
    public var artistCount: Int?
    public var bookCount: Int?

    enum CodingKeys: String, CodingKey {
        case movieCount = "MovieCount", seriesCount = "SeriesCount", episodeCount = "EpisodeCount", albumCount = "AlbumCount"
        case songCount = "SongCount", artistCount = "ArtistCount", bookCount = "BookCount"
    }
}

public struct JellyfinUser: Decodable, Sendable, Identifiable, Hashable {
    public struct Policy: Decodable, Sendable, Hashable {
        public var isAdministrator: Bool?
        public var isDisabled: Bool?
        public var enableRemoteAccess: Bool?
        enum CodingKeys: String, CodingKey { case isAdministrator = "IsAdministrator", isDisabled = "IsDisabled", enableRemoteAccess = "EnableRemoteAccess" }
    }
    public var id: String
    public var name: String
    public var lastActivityDate: Date?
    public var lastLoginDate: Date?
    public var hasPassword: Bool?
    public var policy: Policy?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", lastActivityDate = "LastActivityDate", lastLoginDate = "LastLoginDate", hasPassword = "HasPassword", policy = "Policy"
    }

    public var isAdmin: Bool { policy?.isAdministrator == true }
    public var isDisabled: Bool { policy?.isDisabled == true }
}

public struct ScheduledTask: Decodable, Sendable, Identifiable, Hashable {
    public struct Result: Decodable, Sendable, Hashable {
        public var endTimeUtc: Date?
        public var status: String?
        enum CodingKeys: String, CodingKey { case endTimeUtc = "EndTimeUtc", status = "Status" }
    }
    public var id: String
    public var name: String
    public var category: String?
    public var state: String?
    public var description: String?
    public var currentProgressPercentage: Double?
    public var lastExecutionResult: Result?
    public var isHidden: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", category = "Category", state = "State", description = "Description"
        case currentProgressPercentage = "CurrentProgressPercentage", lastExecutionResult = "LastExecutionResult", isHidden = "IsHidden"
    }

    public var isRunning: Bool { state == "Running" || state == "Cancelling" }
}

public struct ActivityEntry: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var name: String?
    public var type: String?
    public var date: Date?
    public var severity: String?
    public var shortOverview: String?

    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", type = "Type", date = "Date", severity = "Severity", shortOverview = "ShortOverview" }
}

public struct JellyfinPage<T: Decodable & Sendable>: Decodable, Sendable {
    public var items: [T]
    public var totalRecordCount: Int?
    enum CodingKeys: String, CodingKey { case items = "Items", totalRecordCount = "TotalRecordCount" }
}

public struct JellyfinAuthResult: Decodable, Sendable {
    public var accessToken: String
    public var user: JellyfinUser
    enum CodingKeys: String, CodingKey { case accessToken = "AccessToken", user = "User" }
}

public enum JellyfinPlaystateCommand: String, Sendable { case stop = "Stop", pause = "Pause", unpause = "Unpause", next = "NextTrack", previous = "PreviousTrack" }

public struct JellyfinClient: Sendable {
    public let client: ServiceClient
    public init(client: ServiceClient) { self.client = client }

    /// Signs in with an administrator account and returns the access token to store as the "API key".
    public func authenticate(username: String, password: String) async throws -> JellyfinAuthResult {
        try await client.send(.post, "Users/AuthenticateByName", json: ["Username": username, "Pw": password])
    }

    public func systemInfo() async throws -> JellyfinSystemInfo { try await client.get("System/Info") }

    public func sessions(activeWithinSeconds: Int = 960) async throws -> [JellyfinSession] {
        try await client.get("Sessions", query: [URLQueryItem(name: "activeWithinSeconds", value: String(activeWithinSeconds))])
    }

    public func send(_ command: JellyfinPlaystateCommand, to sessionId: String) async throws {
        try await client.perform(.post, "Sessions/\(sessionId)/Playing/\(command.rawValue)")
    }

    public func message(sessionId: String, header: String, text: String, timeoutMs: Int = 8000) async throws {
        try await client.perform(.post, "Sessions/\(sessionId)/Message", json: MessageBody(Header: header, Text: text, TimeoutMs: timeoutMs))
    }

    public func libraries() async throws -> [VirtualFolder] { try await client.get("Library/VirtualFolders") }
    public func itemCounts() async throws -> ItemCounts { try await client.get("Items/Counts") }
    public func scanAllLibraries() async throws { try await client.perform(.post, "Library/Refresh") }

    public func refresh(itemId: String, replaceAllMetadata: Bool = false) async throws {
        try await client.perform(.post, "Items/\(itemId)/Refresh", query: [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "MetadataRefreshMode", value: replaceAllMetadata ? "FullRefresh" : "Default"),
            URLQueryItem(name: "ImageRefreshMode", value: replaceAllMetadata ? "FullRefresh" : "Default"),
            URLQueryItem(name: "ReplaceAllMetadata", value: String(replaceAllMetadata)),
            URLQueryItem(name: "ReplaceAllImages", value: String(replaceAllMetadata)),
        ])
    }

    public func latestItems(limit: Int = 20) async throws -> [JellyfinItem] {
        let page: JellyfinPage<JellyfinItem> = try await client.get("Items", query: [
            URLQueryItem(name: "SortBy", value: "DateCreated"), URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,MusicAlbum"),
            URLQueryItem(name: "Limit", value: String(limit)), URLQueryItem(name: "Fields", value: "DateCreated"),
        ])
        return page.items
    }

    public func users() async throws -> [JellyfinUser] { try await client.get("Users") }

    @discardableResult
    public func createUser(name: String, password: String) async throws -> JellyfinUser {
        try await client.send(.post, "Users/New", json: ["Name": name, "Password": password])
    }

    public func deleteUser(_ id: String) async throws { try await client.perform(.delete, "Users/\(id)") }

    public func setPassword(userId: String, newPassword: String) async throws {
        try await client.perform(.post, "Users/\(userId)/Password", json: ["CurrentPw": "", "NewPw": newPassword])
    }

    /// Edits the user's full policy document (Jellyfin replaces it as a whole).
    public func updatePolicy(userId: String, _ edit: (inout JSONValue) -> Void) async throws {
        let user: JSONValue = try await client.get("Users/\(userId)")
        guard var policy = user["Policy"] else { throw ServiceError.decoding("user has no Policy") }
        edit(&policy)
        try await client.perform(.post, "Users/\(userId)/Policy", json: policy)
    }

    public func setDisabled(userId: String, _ disabled: Bool) async throws {
        try await updatePolicy(userId: userId) { $0["IsDisabled"] = .bool(disabled) }
    }

    public func setAdministrator(userId: String, _ admin: Bool) async throws {
        try await updatePolicy(userId: userId) { $0["IsAdministrator"] = .bool(admin) }
    }

    public func scheduledTasks() async throws -> [ScheduledTask] {
        try await client.get("ScheduledTasks", query: [URLQueryItem(name: "isHidden", value: "false")])
    }
    public func run(taskId: String) async throws { try await client.perform(.post, "ScheduledTasks/Running/\(taskId)") }
    public func stop(taskId: String) async throws { try await client.perform(.delete, "ScheduledTasks/Running/\(taskId)") }

    public func activityLog(limit: Int = 50) async throws -> [ActivityEntry] {
        let page: JellyfinPage<ActivityEntry> = try await client.get("System/ActivityLog/Entries", query: [
            URLQueryItem(name: "startIndex", value: "0"), URLQueryItem(name: "limit", value: String(limit)),
        ])
        return page.items
    }

    public func restart() async throws { try await client.perform(.post, "System/Restart") }
    public func shutdown() async throws { try await client.perform(.post, "System/Shutdown") }

    /// URL for an item's primary image (fetch with this client's headers; images may require auth).
    public func imageURL(itemId: String, maxHeight: Int = 300) -> URL? {
        try? client.url("Items/\(itemId)/Images/Primary", query: [URLQueryItem(name: "maxHeight", value: String(maxHeight)), URLQueryItem(name: "quality", value: "85")])
    }

    struct MessageBody: Encodable {
        var Header: String
        var Text: String
        var TimeoutMs: Int
    }
}
