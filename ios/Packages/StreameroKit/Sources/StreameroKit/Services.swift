import Foundation

/// The services Streamero manages.
public enum ServiceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case jellyfin, seerr, sonarr, radarr, lidarr, prowlarr, bazarr, qbittorrent, sabnzbd

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .seerr: "Jellyseerr / Overseerr"
        case .sonarr: "Sonarr"
        case .radarr: "Radarr"
        case .lidarr: "Lidarr"
        case .prowlarr: "Prowlarr"
        case .bazarr: "Bazarr"
        case .qbittorrent: "qBittorrent"
        case .sabnzbd: "SABnzbd"
        }
    }

    public var role: String {
        switch self {
        case .jellyfin: "Media server"
        case .seerr: "Requests"
        case .sonarr: "TV series"
        case .radarr: "Movies"
        case .lidarr: "Music"
        case .prowlarr: "Indexers"
        case .bazarr: "Subtitles"
        case .qbittorrent: "Torrent client"
        case .sabnzbd: "Usenet client"
        }
    }

    /// Suggested address for streamero.net; always editable in Settings.
    public var defaultURL: String {
        switch self {
        case .jellyfin: "https://streamero.net"
        case .seerr: "https://req.streamero.net"
        case .sonarr: "https://son.streamero.net"
        case .radarr: "https://rad.streamero.net"
        case .lidarr: "https://lid.streamero.net"
        case .prowlarr: "https://prow.streamero.net"
        case .bazarr: "https://baz.streamero.net"
        case .qbittorrent: "https://qbit.streamero.net"
        case .sabnzbd: "https://sab.streamero.net"
        }
    }

    /// Where the user finds the API key in the service's web UI.
    public var apiKeyHint: String {
        switch self {
        case .jellyfin: "Dashboard → API Keys → +, or sign in with an administrator account below"
        case .seerr: "Settings → General → API Key"
        case .sonarr, .radarr, .lidarr, .prowlarr: "Settings → General → Security → API Key"
        case .bazarr: "Settings → General → Security → API Key"
        case .qbittorrent: "enter the Web UI password here and the user name below (Tools → Options → Web UI)"
        case .sabnzbd: "Config → General → Security → API Key"
        }
    }

    /// Several instances make sense for these (e.g. Jellyseerr and a second Overseerr, Radarr 4K).
    public var allowsMultiple: Bool { self != .jellyfin }
}

/// One configured service. Stored (with its secrets) in the Keychain by the app.
public struct ServiceInstance: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var kind: ServiceKind
    public var name: String
    public var url: String
    public var apiKey: String
    /// Jellyfin only: account used to obtain `apiKey` as an access token (password is never stored).
    public var username: String?
    public var enabled: Bool

    public init(id: UUID = UUID(), kind: ServiceKind, name: String? = nil, url: String? = nil, apiKey: String = "", username: String? = nil, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.url = url ?? kind.defaultURL
        self.apiKey = apiKey
        self.username = username
        self.enabled = enabled
    }

    public var isConfigured: Bool { enabled && !apiKey.isEmpty && Self.normalisedURL(url) != nil }

    /// Accepts "son.streamero.net", trailing slashes and whitespace; defaults to https.
    public static func normalisedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}

/// Builds the HTTP client for an instance with the right base path and auth header.
public enum ServiceClients {
    public static let jellyfinClientName = "Streamero"

    public static func client(for instance: ServiceInstance, deviceId: String = "streamero-ios", appVersion: String = "2.0", transport: HTTPTransport = URLSessionTransport()) throws -> ServiceClient {
        guard let base = ServiceInstance.normalisedURL(instance.url) else { throw ServiceError.invalidURL(instance.url) }
        switch instance.kind {
        case .jellyfin:
            return ServiceClient(baseURL: base, headers: ["Authorization": jellyfinAuthorization(token: instance.apiKey, deviceId: deviceId, version: appVersion)], transport: transport)
        case .seerr:
            return ServiceClient(baseURL: base, prefix: "api/v1", headers: ["X-Api-Key": instance.apiKey], transport: transport)
        case .sonarr, .radarr:
            return ServiceClient(baseURL: base, prefix: "api/v3", headers: ["X-Api-Key": instance.apiKey], transport: transport)
        case .lidarr, .prowlarr:
            return ServiceClient(baseURL: base, prefix: "api/v1", headers: ["X-Api-Key": instance.apiKey], transport: transport)
        case .bazarr:
            return ServiceClient(baseURL: base, prefix: "api", headers: ["X-API-KEY": instance.apiKey], transport: transport)
        case .qbittorrent:
            // qBittorrent checks Referer/Origin against its own host (CSRF protection); auth is a session cookie.
            return ServiceClient(baseURL: base, prefix: "api/v2", headers: ["Referer": base.absoluteString, "Origin": base.absoluteString], transport: transport)
        case .sabnzbd:
            var client = ServiceClient(baseURL: base, prefix: "api", transport: transport)
            client.defaultQuery = [URLQueryItem(name: "output", value: "json"), URLQueryItem(name: "apikey", value: instance.apiKey)]
            return client
        }
    }

    /// Jellyfin's `Authorization: MediaBrowser …` header; works with API keys and user access tokens.
    public static func jellyfinAuthorization(token: String?, deviceId: String, version: String, device: String = "iPhone") -> String {
        var parts = [
            "Client=\"\(jellyfinClientName)\"",
            "Device=\"\(device)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(version)\"",
        ]
        if let token, !token.isEmpty { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }
}
