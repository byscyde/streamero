import Foundation

// Jellyfin administration beyond the basics: plugins and catalog, devices, API keys, libraries,
// per-user permissions and server log files.

public struct JellyfinPlugin: Decodable, Sendable, Identifiable, Hashable {
    public var name: String
    public var version: String
    public var id: String
    public var status: String?
    public var description: String?
    public var canUninstall: Bool?

    enum CodingKeys: String, CodingKey { case name = "Name", version = "Version", id = "Id", status = "Status", description = "Description", canUninstall = "CanUninstall" }

    public var isActive: Bool { status == "Active" }
    public var needsRestart: Bool { status == "Restart" }
}

public struct JellyfinPackage: Decodable, Sendable, Identifiable, Hashable {
    public struct Version: Decodable, Sendable, Hashable { public var version: String? }
    public var name: String
    public var description: String?
    public var overview: String?
    public var category: String?
    public var guid: String
    public var versions: [Version]?
    public var id: String { guid }
    public var latestVersion: String? { versions?.first?.version }
}

public struct JellyfinDevice: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String?
    public var appName: String?
    public var appVersion: String?
    public var lastUserName: String?
    public var dateLastActivity: Date?

    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", appName = "AppName", appVersion = "AppVersion", lastUserName = "LastUserName", dateLastActivity = "DateLastActivity" }
}

public struct JellyfinApiKey: Decodable, Sendable, Identifiable, Hashable {
    public var accessToken: String
    public var appName: String?
    public var dateCreated: Date?
    public var id: String { accessToken }

    enum CodingKeys: String, CodingKey { case accessToken = "AccessToken", appName = "AppName", dateCreated = "DateCreated" }
}

public struct JellyfinLogFile: Decodable, Sendable, Identifiable, Hashable {
    public var name: String
    public var size: Double?
    public var dateModified: Date?
    public var id: String { name }

    enum CodingKeys: String, CodingKey { case name = "Name", size = "Size", dateModified = "DateModified" }
}

/// The user policy switches an admin usually changes.
public enum JellyfinPermission: String, CaseIterable, Sendable, Identifiable {
    case isAdministrator = "IsAdministrator"
    case isDisabled = "IsDisabled"
    case isHidden = "IsHidden"
    case enableRemoteAccess = "EnableRemoteAccess"
    case enableMediaPlayback = "EnableMediaPlayback"
    case enableAudioPlaybackTranscoding = "EnableAudioPlaybackTranscoding"
    case enableVideoPlaybackTranscoding = "EnableVideoPlaybackTranscoding"
    case enablePlaybackRemuxing = "EnablePlaybackRemuxing"
    case enableContentDownloading = "EnableContentDownloading"
    case enableContentDeletion = "EnableContentDeletion"
    case enableLiveTvAccess = "EnableLiveTvAccess"
    case enableLiveTvManagement = "EnableLiveTvManagement"
    case enableSubtitleManagement = "EnableSubtitleManagement"
    case enableCollectionManagement = "EnableCollectionManagement"
    case enableRemoteControlOfOtherUsers = "EnableRemoteControlOfOtherUsers"
    case enableSharedDeviceControl = "EnableSharedDeviceControl"
    case enablePublicSharing = "EnablePublicSharing"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .isAdministrator: "Administrator"
        case .isDisabled: "Disabled"
        case .isHidden: "Hidden from login screen"
        case .enableRemoteAccess: "Remote access"
        case .enableMediaPlayback: "Media playback"
        case .enableAudioPlaybackTranscoding: "Audio transcoding"
        case .enableVideoPlaybackTranscoding: "Video transcoding"
        case .enablePlaybackRemuxing: "Remuxing"
        case .enableContentDownloading: "Downloads"
        case .enableContentDeletion: "Delete media"
        case .enableLiveTvAccess: "Live TV"
        case .enableLiveTvManagement: "Manage Live TV"
        case .enableSubtitleManagement: "Manage subtitles"
        case .enableCollectionManagement: "Manage collections"
        case .enableRemoteControlOfOtherUsers: "Control other users"
        case .enableSharedDeviceControl: "Control shared devices"
        case .enablePublicSharing: "Public sharing"
        }
    }
}

/// Editable view of a user's policy (raw document plus helpers).
public struct JellyfinPolicy: Sendable, Hashable {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }

    public func flag(_ permission: JellyfinPermission) -> Bool { raw[permission.rawValue]?.boolValue ?? false }
    public mutating func set(_ permission: JellyfinPermission, _ value: Bool) { raw[permission.rawValue] = .bool(value) }

    public var allLibraries: Bool {
        get { raw["EnableAllFolders"]?.boolValue ?? true }
        set { raw["EnableAllFolders"] = .bool(newValue) }
    }

    public var enabledLibraries: Set<String> {
        get { Set((raw["EnabledFolders"]?.arrayValue ?? []).compactMap(\.stringValue)) }
        set { raw["EnabledFolders"] = .array(newValue.sorted().map(JSONValue.string)) }
    }

    public var maxActiveSessions: Int {
        get { raw["MaxActiveSessions"]?.intValue ?? 0 }
        set { raw["MaxActiveSessions"] = JSONValue(newValue) }
    }

    /// Bits per second; 0 = unlimited.
    public var remoteBitrateLimit: Int {
        get { raw["RemoteClientBitrateLimit"]?.intValue ?? 0 }
        set { raw["RemoteClientBitrateLimit"] = JSONValue(newValue) }
    }
}

public enum JellyfinCollectionType: String, CaseIterable, Sendable, Identifiable {
    case movies, tvshows, music, musicvideos, homevideos, books, boxsets, mixed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .movies: "Movies"
        case .tvshows: "Shows"
        case .music: "Music"
        case .musicvideos: "Music videos"
        case .homevideos: "Home videos & photos"
        case .books: "Books"
        case .boxsets: "Collections"
        case .mixed: "Mixed movies and shows"
        }
    }
}

extension JellyfinClient {
    public func plugins() async throws -> [JellyfinPlugin] { try await client.get("Plugins") }
    public func setPlugin(_ plugin: JellyfinPlugin, enabled: Bool) async throws {
        try await client.perform(.post, "Plugins/\(plugin.id)/\(plugin.version)/\(enabled ? "Enable" : "Disable")")
    }
    public func uninstall(_ plugin: JellyfinPlugin) async throws { try await client.perform(.delete, "Plugins/\(plugin.id)/\(plugin.version)") }

    public func catalog() async throws -> [JellyfinPackage] {
        // Package keys are camelCase in 10.9+ ("name", "guid"); older servers use PascalCase.
        let raw: [JSONValue] = try await client.get("Packages")
        return raw.compactMap { item in
            if let package = try? item.decode(JellyfinPackage.self) { return package }
            guard case .object(let dict) = item else { return nil }
            var lowered: [String: JSONValue] = [:]
            for (key, value) in dict { lowered[key.prefix(1).lowercased() + key.dropFirst()] = value }
            return try? JSONValue.object(lowered).decode(JellyfinPackage.self)
        }
    }

    public func install(_ package: JellyfinPackage) async throws {
        var query = [URLQueryItem(name: "assemblyGuid", value: package.guid)]
        if let version = package.latestVersion { query.append(URLQueryItem(name: "version", value: version)) }
        try await client.perform(.post, "Packages/Installed/\(package.name)", query: query)
    }

    public func devices() async throws -> [JellyfinDevice] {
        let page: JellyfinPage<JellyfinDevice> = try await client.get("Devices")
        return page.items
    }
    public func deleteDevice(_ id: String) async throws { try await client.perform(.delete, "Devices", query: [URLQueryItem(name: "id", value: id)]) }

    public func apiKeys() async throws -> [JellyfinApiKey] {
        let page: JellyfinPage<JellyfinApiKey> = try await client.get("Auth/Keys")
        return page.items
    }
    public func createApiKey(app: String) async throws { try await client.perform(.post, "Auth/Keys", query: [URLQueryItem(name: "app", value: app)]) }
    public func revokeApiKey(_ key: String) async throws { try await client.perform(.delete, "Auth/Keys/\(key)") }

    public func addLibrary(name: String, type: JellyfinCollectionType, paths: [String]) async throws {
        var query = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "collectionType", value: type.rawValue), URLQueryItem(name: "refreshLibrary", value: "true")]
        query += paths.map { URLQueryItem(name: "paths", value: $0) }
        try await client.perform(.post, "Library/VirtualFolders", query: query, json: ["LibraryOptions": JSONValue.object([:])])
    }
    public func removeLibrary(name: String) async throws {
        try await client.perform(.delete, "Library/VirtualFolders", query: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "refreshLibrary", value: "true")])
    }
    public func addPath(_ path: String, toLibrary name: String) async throws {
        try await client.perform(.post, "Library/VirtualFolders/Paths", query: [URLQueryItem(name: "refreshLibrary", value: "true")],
                                 json: ["Name": JSONValue.string(name), "PathInfo": .object(["Path": .string(path)])])
    }
    public func removePath(_ path: String, fromLibrary name: String) async throws {
        try await client.perform(.delete, "Library/VirtualFolders/Paths", query: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "path", value: path), URLQueryItem(name: "refreshLibrary", value: "true")])
    }

    public func policy(userId: String) async throws -> JellyfinPolicy {
        let user: JSONValue = try await client.get("Users/\(userId)")
        guard let policy = user["Policy"] else { throw ServiceError.decoding("user has no Policy") }
        return JellyfinPolicy(raw: policy)
    }
    public func save(_ policy: JellyfinPolicy, userId: String) async throws { try await client.perform(.post, "Users/\(userId)/Policy", json: policy.raw) }

    public func logFiles() async throws -> [JellyfinLogFile] { try await client.get("System/Logs") }
    public func logFile(_ name: String) async throws -> String {
        String(decoding: try await client.data(.get, "System/Logs/Log", query: [URLQueryItem(name: "name", value: name)]), as: UTF8.self)
    }
}
