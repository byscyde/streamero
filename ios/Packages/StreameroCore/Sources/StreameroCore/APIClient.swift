import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.network("Invalid response") }
        return (data, http)
    }
}

/// Persists tokens (Keychain on device). Must be thread-safe.
public protocol TokenStore: Sendable {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens?)
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?
    public init(_ tokens: AuthTokens? = nil) { self.tokens = tokens }
    public func load() -> AuthTokens? { lock.withLock { tokens } }
    public func save(_ tokens: AuthTokens?) { lock.withLock { self.tokens = tokens } }
}

public enum APIError: Error, Sendable, Equatable, LocalizedError {
    /// Server responded with a structured error.
    case server(status: Int, code: String, message: String, details: JSONValue?)
    /// No connectivity or transport failure.
    case network(String)
    case decoding(String)
    /// Refresh failed: the user must sign in again.
    case sessionExpired

    public var errorDescription: String? {
        switch self {
        case .server(_, _, let message, _): message
        case .network: "You appear to be offline. Check your connection and try again."
        case .decoding: "The server sent an unexpected response."
        case .sessionExpired: "Your session has ended. Please sign in again."
        }
    }

    public var code: String? { if case .server(_, let c, _, _) = self { return c }; return nil }
    public var status: Int? { if case .server(let s, _, _, _) = self { return s }; return nil }
    public var isOffline: Bool { if case .network = self { return true }; return false }
    public var isNotFound: Bool { status == 404 }
}

struct ErrorEnvelope: Decodable {
    struct Body: Decodable { var code: String; var message: String; var details: JSONValue? }
    var error: Body
}

/// Owns tokens and serialises refreshes: concurrent requests that hit an expired token share one refresh.
public actor AuthManager {
    private let store: TokenStore
    private var tokens: AuthTokens?
    private var refreshTask: Task<AuthTokens, Error>?
    private var onExpired: (@Sendable () -> Void)?
    private let now: @Sendable () -> Date

    public init(store: TokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.tokens = store.load()
        self.now = now
    }

    public var isSignedIn: Bool { tokens != nil }
    public var currentTokens: AuthTokens? { tokens }

    public func setOnExpired(_ handler: @escaping @Sendable () -> Void) { onExpired = handler }

    public func update(_ new: AuthTokens?) {
        tokens = new
        store.save(new)
    }

    /// Returns an access token valid for at least 30 s, refreshing first if needed.
    func validAccessToken(refresh: @escaping @Sendable (String) async throws -> AuthTokens) async throws -> String? {
        guard let t = tokens else { return nil }
        if t.accessExpiresAt.timeIntervalSince(now()) > 30 { return t.accessToken }
        return try await forceRefresh(refresh: refresh).accessToken
    }

    func forceRefresh(refresh: @escaping @Sendable (String) async throws -> AuthTokens) async throws -> AuthTokens {
        if let task = refreshTask { return try await task.value }
        guard let refreshToken = tokens?.refreshToken else { throw APIError.sessionExpired }
        let task = Task { try await refresh(refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let new = try await task.value
            update(new)
            return new
        } catch let error as APIError {
            // Only a definitive rejection ends the session; offline refresh failures keep tokens for later.
            if case .server(let status, _, _, _) = error, status == 401 || status == 403 {
                update(nil)
                onExpired?()
                throw APIError.sessionExpired
            }
            throw error
        }
    }
}

public struct Endpoint: Sendable {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var contentType: String?
    public var requiresAuth: Bool

    public init(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = "application/json", requiresAuth: Bool = true) {
        self.method = method; self.path = path; self.query = query; self.body = body; self.contentType = contentType; self.requiresAuth = requiresAuth
    }

    public static func json<B: Encodable>(_ method: String, _ path: String, _ body: B, requiresAuth: Bool = true) -> Endpoint {
        Endpoint(method, path, body: try? JSONEncoder.streamero.encode(body), requiresAuth: requiresAuth)
    }
}

public struct EmptyResponse: Decodable, Sendable { public init() {} }

public final class APIClient: Sendable {
    public let baseURL: URL
    public let auth: AuthManager
    private let transport: HTTPTransport
    private let userAgent: String

    public init(baseURL: URL, tokenStore: TokenStore, transport: HTTPTransport = URLSessionTransport(), userAgent: String = "STREAMERO-iOS") {
        self.baseURL = baseURL
        self.auth = AuthManager(store: tokenStore)
        self.transport = transport
        self.userAgent = userAgent
    }

    func makeRequest(_ e: Endpoint, token: String?) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(e.path), resolvingAgainstBaseURL: false) else {
            throw APIError.network("Invalid server URL")
        }
        if !e.query.isEmpty { comps.queryItems = e.query }
        guard let url = comps.url else { throw APIError.network("Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = e.method
        req.httpBody = e.body
        if e.body != nil, let ct = e.contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func refreshClosure() -> @Sendable (String) async throws -> AuthTokens {
        { [self] refreshToken in
            let session: Session = try await self.raw(.json("POST", "v1/auth/refresh", ["refreshToken": refreshToken], requiresAuth: false), token: nil)
            return AuthTokens(session: session)
        }
    }

    private func raw<T: Decodable>(_ e: Endpoint, token: String?) async throws -> T {
        let (data, http) = try await perform(e, token: token)
        return try decode(data, status: http.statusCode)
    }

    private func perform(_ e: Endpoint, token: String?) async throws -> (Data, HTTPURLResponse) {
        let req = try makeRequest(e, token: token)
        do {
            return try await transport.send(req)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ data: Data, status: Int) throws -> T {
        guard (200..<300).contains(status) else {
            if let env = try? JSONDecoder.streamero.decode(ErrorEnvelope.self, from: data) {
                throw APIError.server(status: status, code: env.error.code, message: env.error.message, details: env.error.details)
            }
            throw APIError.server(status: status, code: "http_\(status)", message: "Request failed (\(status))", details: nil)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do {
            return try JSONDecoder.streamero.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Sends a request, attaching a fresh access token and retrying once after a 401.
    public func send<T: Decodable>(_ e: Endpoint, as: T.Type = T.self) async throws -> T {
        guard e.requiresAuth else { return try await raw(e, token: nil) }
        let refresh = refreshClosure()
        let token = try await auth.validAccessToken(refresh: refresh)
        guard let token else { throw APIError.sessionExpired }
        let (data, http) = try await perform(e, token: token)
        if http.statusCode == 401 {
            let fresh = try await auth.forceRefresh(refresh: refresh)
            let (d2, h2) = try await perform(e, token: fresh.accessToken)
            return try decode(d2, status: h2.statusCode)
        }
        return try decode(data, status: http.statusCode)
    }

    @discardableResult
    public func sendEmpty(_ e: Endpoint) async throws -> EmptyResponse { try await send(e) }
}

// MARK: - Typed API

public extension APIClient {
    private static func page(_ limit: Int, _ offset: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
    }

    // Auth
    func login(email: String, password: String) async throws -> Session {
        let s: Session = try await send(.json("POST", "v1/auth/login", ["email": email, "password": password, "deviceName": userAgent], requiresAuth: false))
        await auth.update(AuthTokens(session: s))
        return s
    }

    func register(email: String, password: String, displayName: String) async throws -> Session {
        let s: Session = try await send(.json("POST", "v1/auth/register", ["email": email, "password": password, "displayName": displayName], requiresAuth: false))
        await auth.update(AuthTokens(session: s))
        return s
    }

    func signInWithApple(identityToken: String, nonce: String?, displayName: String?) async throws -> Session {
        var body = ["identityToken": identityToken]
        if let nonce { body["nonce"] = nonce }
        if let displayName { body["displayName"] = displayName }
        let s: Session = try await send(.json("POST", "v1/auth/apple", body, requiresAuth: false))
        await auth.update(AuthTokens(session: s))
        return s
    }

    func logout() async {
        if let t = await auth.currentTokens {
            _ = try? await sendEmpty(.json("POST", "v1/auth/logout", ["refreshToken": t.refreshToken], requiresAuth: false))
        }
        await auth.update(nil)
    }

    func forgotPassword(email: String) async throws { try await sendEmpty(.json("POST", "v1/auth/forgot-password", ["email": email], requiresAuth: false)) }
    func resetPassword(token: String, password: String) async throws { try await sendEmpty(.json("POST", "v1/auth/reset-password", ["token": token, "password": password], requiresAuth: false)) }
    func verifyEmail(token: String) async throws { try await sendEmpty(.json("POST", "v1/auth/verify-email", ["token": token], requiresAuth: false)) }
    func resendVerification() async throws { try await sendEmpty(Endpoint("POST", "v1/auth/resend-verification")) }

    // Account
    func me() async throws -> User { try await send(Endpoint("GET", "v1/me")) }
    func updateProfile(_ patch: [String: JSONValue]) async throws -> User { try await send(.json("PATCH", "v1/me", patch)) }
    func putPreferences(_ prefs: JSONValue, baseVersion: Int) async throws -> JSONValue {
        try await send(.json("PUT", "v1/me/preferences", ["preferences": prefs, "baseVersion": .number(Double(baseVersion))]))
    }
    func exportData() async throws -> Data {
        let json: JSONValue = try await send(Endpoint("GET", "v1/me/export"))
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(json)
    }
    func deleteAccount(password: String?) async throws {
        try await sendEmpty(.json("DELETE", "v1/me", password.map { ["password": $0] } ?? [:]))
        await auth.update(nil)
    }

    // Catalog
    func home() async throws -> HomeFeed { try await send(Endpoint("GET", "v1/home")) }
    func track(_ id: String) async throws -> Track { try await send(Endpoint("GET", "v1/tracks/\(id)")) }
    func tracks(ids: [String]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let r: ItemsResponse<Track> = try await send(Endpoint("GET", "v1/tracks", query: [URLQueryItem(name: "ids", value: ids.prefix(200).joined(separator: ","))]))
        return r.items
    }
    func lyrics(trackId: String) async throws -> LyricsResponse { try await send(Endpoint("GET", "v1/tracks/\(trackId)/lyrics")) }
    func artist(_ id: String) async throws -> ArtistPage { try await send(Endpoint("GET", "v1/artists/\(id)")) }
    func album(_ id: String) async throws -> AlbumPage { try await send(Endpoint("GET", "v1/albums/\(id)")) }
    func videos(limit: Int = 30, offset: Int = 0, genre: String? = nil) async throws -> Page<Video> {
        var q = Self.page(limit, offset)
        if let genre { q.append(URLQueryItem(name: "genre", value: genre)) }
        return try await send(Endpoint("GET", "v1/videos", query: q))
    }
    func video(_ id: String) async throws -> VideoPage { try await send(Endpoint("GET", "v1/videos/\(id)")) }
    func genres() async throws -> GenresResponse { try await send(Endpoint("GET", "v1/genres")) }
    func tagTracks(kind: String, name: String, limit: Int = 50, offset: Int = 0) async throws -> Page<Track> {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return try await send(Endpoint("GET", "v1/\(kind == "mood" ? "moods" : "genres")/\(encoded)/tracks", query: Self.page(limit, offset)))
    }
    func mixes() async throws -> [Mix] { (try await send(Endpoint("GET", "v1/mixes")) as ItemsResponse<Mix>).items }
    func mix(_ id: String) async throws -> MixDetail {
        try await send(Endpoint("GET", "v1/mixes/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id)"))
    }
    func trending() async throws -> [Track] { (try await send(Endpoint("GET", "v1/charts/trending")) as ItemsResponse<Track>).items }

    // Search
    func search(_ q: String, types: [String] = [], limit: Int = 20, offset: Int = 0) async throws -> SearchResponse {
        var query = [URLQueryItem(name: "q", value: q)] + Self.page(limit, offset)
        if !types.isEmpty { query.append(URLQueryItem(name: "types", value: types.joined(separator: ","))) }
        return try await send(Endpoint("GET", "v1/search", query: query))
    }
    func suggestions(_ q: String) async throws -> [SearchSuggestion] {
        (try await send(Endpoint("GET", "v1/search/suggestions", query: [URLQueryItem(name: "q", value: q)])) as ItemsResponse<SearchSuggestion>).items
    }
    func recentSearches() async throws -> [RecentSearch] { (try await send(Endpoint("GET", "v1/me/recent-searches")) as ItemsResponse<RecentSearch>).items }
    func addRecentSearch(_ q: String) async throws { try await sendEmpty(.json("POST", "v1/me/recent-searches", ["query": q])) }
    func clearRecentSearches() async throws { try await sendEmpty(Endpoint("DELETE", "v1/me/recent-searches")) }

    // Library
    func librarySummary() async throws -> LibrarySummary { try await send(Endpoint("GET", "v1/me/library")) }
    func libraryIds() async throws -> LibraryIds { try await send(Endpoint("GET", "v1/me/library/ids")) }
    func syncLibrary(_ changes: [LibraryChange]) async throws { try await sendEmpty(.json("POST", "v1/me/library/sync", ["changes": changes])) }
    func likedTracks(limit: Int = 50, offset: Int = 0, sort: String = "recent", filter: String? = nil) async throws -> Page<Track> {
        var q = Self.page(limit, offset) + [URLQueryItem(name: "sort", value: sort)]
        if let filter, !filter.isEmpty { q.append(URLQueryItem(name: "q", value: filter)) }
        return try await send(Endpoint("GET", "v1/me/liked/tracks", query: q))
    }
    func savedAlbums(limit: Int = 50, offset: Int = 0, sort: String = "recent") async throws -> Page<Album> {
        try await send(Endpoint("GET", "v1/me/albums", query: Self.page(limit, offset) + [URLQueryItem(name: "sort", value: sort)]))
    }
    func followedArtists(limit: Int = 50, offset: Int = 0, sort: String = "title") async throws -> Page<Artist> {
        try await send(Endpoint("GET", "v1/me/following/artists", query: Self.page(limit, offset) + [URLQueryItem(name: "sort", value: sort)]))
    }
    func likedVideos(limit: Int = 50, offset: Int = 0) async throws -> Page<Video> { try await send(Endpoint("GET", "v1/me/liked/videos", query: Self.page(limit, offset))) }
    func myPlaylists(limit: Int = 50, offset: Int = 0, sort: String = "recent") async throws -> Page<Playlist> {
        try await send(Endpoint("GET", "v1/me/playlists", query: Self.page(limit, offset) + [URLQueryItem(name: "sort", value: sort)]))
    }

    // Playlists
    func playlist(_ id: String, limit: Int = 200, offset: Int = 0) async throws -> PlaylistPage { try await send(Endpoint("GET", "v1/playlists/\(id)", query: Self.page(limit, offset))) }
    func createPlaylist(title: String, description: String?, visibility: String = "private") async throws -> PlaylistPage {
        var body: [String: String] = ["title": title, "visibility": visibility]
        if let description, !description.isEmpty { body["description"] = description }
        return try await send(.json("POST", "v1/playlists", body))
    }
    func updatePlaylist(_ id: String, patch: [String: JSONValue]) async throws -> PlaylistPage { try await send(.json("PATCH", "v1/playlists/\(id)", patch)) }
    func deletePlaylist(_ id: String) async throws { try await sendEmpty(Endpoint("DELETE", "v1/playlists/\(id)")) }
    func addToPlaylist(_ id: String, trackIds: [String] = [], videoIds: [String] = []) async throws -> PlaylistPage {
        try await send(.json("POST", "v1/playlists/\(id)/items", ["trackIds": trackIds, "videoIds": videoIds]))
    }
    func removeFromPlaylist(_ id: String, itemIds: [String], expectedVersion: Int?) async throws -> PlaylistPage {
        var body: [String: JSONValue] = ["itemIds": .array(itemIds.map { .string($0) })]
        if let v = expectedVersion { body["expectedVersion"] = .number(Double(v)) }
        return try await send(.json("POST", "v1/playlists/\(id)/items/remove", body))
    }
    func movePlaylistItem(_ id: String, itemId: String, toIndex: Int, expectedVersion: Int?) async throws -> PlaylistPage {
        var body: [String: JSONValue] = ["itemId": .string(itemId), "toIndex": .number(Double(toIndex))]
        if let v = expectedVersion { body["expectedVersion"] = .number(Double(v)) }
        return try await send(.json("POST", "v1/playlists/\(id)/items/move", body))
    }

    // Streaming & playback
    func trackStream(_ id: String, profile: StreamProfile) async throws -> TrackStream {
        try await send(Endpoint("GET", "v1/tracks/\(id)/stream", query: [URLQueryItem(name: "profile", value: profile.rawValue)]))
    }
    func videoStream(_ id: String) async throws -> VideoStream { try await send(Endpoint("GET", "v1/videos/\(id)/stream")) }
    func sendPlaybackEvents(_ events: [PlaybackEvent]) async throws { try await sendEmpty(.json("POST", "v1/me/playback/events", ["events": events])) }
    func recentlyPlayed(limit: Int = 30) async throws -> Page<Track> { try await send(Endpoint("GET", "v1/me/recently-played", query: Self.page(limit, 0))) }
    func saveVideoProgress(_ id: String, positionMs: Int, durationMs: Int, updatedAt: Date = Date()) async throws {
        try await sendEmpty(.json("PUT", "v1/me/progress/videos/\(id)", ["positionMs": JSONValue.number(Double(positionMs)), "durationMs": .number(Double(durationMs)), "updatedAt": .string(StreameroDate.format(updatedAt))]))
    }
    func saveTrackProgress(_ id: String, positionMs: Int) async throws {
        try await sendEmpty(.json("PUT", "v1/me/progress/tracks/\(id)", ["positionMs": positionMs]))
    }
    func playbackState() async throws -> PlaybackStateResponse { try await send(Endpoint("GET", "v1/me/playback-state")) }
    func putPlaybackState(_ snapshot: PlaybackSnapshot, baseVersion: Int, deviceId: String) async throws -> VersionResponse {
        struct Body: Encodable { var state: PlaybackSnapshot; var baseVersion: Int; var deviceId: String }
        return try await send(.json("PUT", "v1/me/playback-state", Body(state: snapshot, baseVersion: baseVersion, deviceId: deviceId)))
    }

    // Downloads
    func requestDownload(trackId: String, profile: StreamProfile) async throws -> DownloadGrant {
        try await send(.json("POST", "v1/me/downloads", ["trackId": trackId, "profile": profile.rawValue]))
    }
    func requestVideoDownload(videoId: String) async throws -> DownloadGrant { try await send(.json("POST", "v1/me/downloads", ["videoId": videoId])) }
    func validateDownloads(_ grantIds: [String]) async throws -> DownloadValidation { try await send(.json("POST", "v1/me/downloads/validate", ["grantIds": grantIds])) }
    func revokeDownload(_ grantId: String) async throws { try await sendEmpty(Endpoint("DELETE", "v1/me/downloads/\(grantId)")) }

    // Sync
    func syncState() async throws -> SyncState { try await send(Endpoint("GET", "v1/sync/state")) }

    // YouTube (official discovery API only)
    func youtubeSearch(_ q: String) async throws -> YouTubeSearch { try await send(Endpoint("GET", "v1/youtube/search", query: [URLQueryItem(name: "q", value: q)])) }
}

/// Library toggles share one endpoint shape: PUT/DELETE /v1/me/<collection>/<id>.
public extension APIClient {
    func setSaved(_ type: LibraryItemType, id: String, saved: Bool) async throws {
        let path: String = switch type {
        case .track: "liked/tracks"
        case .album: "albums"
        case .artist: "following/artists"
        case .video: "liked/videos"
        case .playlist: "saved/playlists"
        }
        try await sendEmpty(Endpoint(saved ? "PUT" : "DELETE", "v1/me/\(path)/\(id)"))
    }
}
