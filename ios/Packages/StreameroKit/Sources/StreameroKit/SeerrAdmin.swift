import Foundation

/// Overseerr/Jellyseerr permission bits the app edits.
public struct SeerrPermissions: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let admin = SeerrPermissions(rawValue: 2)
    public static let manageSettings = SeerrPermissions(rawValue: 4)
    public static let manageUsers = SeerrPermissions(rawValue: 8)
    public static let manageRequests = SeerrPermissions(rawValue: 16)
    public static let request = SeerrPermissions(rawValue: 32)
    public static let autoApprove = SeerrPermissions(rawValue: 128)
    public static let autoApproveMovie = SeerrPermissions(rawValue: 256)
    public static let autoApproveTV = SeerrPermissions(rawValue: 512)
    public static let request4K = SeerrPermissions(rawValue: 1024)
    public static let requestMovie = SeerrPermissions(rawValue: 262_144)
    public static let requestTV = SeerrPermissions(rawValue: 524_288)
    public static let manageIssues = SeerrPermissions(rawValue: 1_048_576)
    public static let createIssues = SeerrPermissions(rawValue: 4_194_304)

    public static let editable: [(SeerrPermissions, String)] = [
        (.admin, "Admin (all permissions)"), (.manageUsers, "Manage users"), (.manageSettings, "Manage settings"),
        (.manageRequests, "Manage requests"), (.request, "Request"), (.requestMovie, "Request movies"), (.requestTV, "Request series"),
        (.request4K, "Request 4K"), (.autoApprove, "Auto-approve"), (.autoApproveMovie, "Auto-approve movies"),
        (.autoApproveTV, "Auto-approve series"), (.manageIssues, "Manage issues"), (.createIssues, "Report issues"),
    ]
}

public struct SeerrManagedUser: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var displayName: String?
    public var email: String?
    public var jellyfinUsername: String?
    public var plexUsername: String?
    public var username: String?
    public var permissions: Int?
    public var requestCount: Int?
    public var createdAt: Date?
    public var userType: Int?
    public var name: String { [displayName, jellyfinUsername, plexUsername, username, email].compactMap { $0 }.first { !$0.isEmpty } ?? "User \(id)" }
    public var permissionSet: SeerrPermissions { SeerrPermissions(rawValue: permissions ?? 0) }
}

public struct SeerrJob: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var type: String?
    public var interval: String?
    public var nextExecutionTime: Date?
    public var running: Bool?
}

extension SeerrClient {
    public func users(take: Int = 100) async throws -> [SeerrManagedUser] {
        let page: SeerrPage<SeerrManagedUser> = try await client.get("user", query: [
            URLQueryItem(name: "take", value: String(take)), URLQueryItem(name: "skip", value: "0"), URLQueryItem(name: "sort", value: "created"),
        ])
        return page.results
    }

    public func setPermissions(userId: Int, _ permissions: SeerrPermissions) async throws {
        try await client.perform(.post, "user/\(userId)/settings/permissions", json: ["permissions": permissions.rawValue])
    }

    public func deleteUser(_ id: Int) async throws { try await client.perform(.delete, "user/\(id)") }

    public func requests(byUser userId: Int, take: Int = 30) async throws -> [SeerrRequest] {
        let page: SeerrPage<SeerrRequest> = try await client.get("user/\(userId)/requests", query: [URLQueryItem(name: "take", value: String(take))])
        return page.results
    }

    /// Imports Jellyfin users into Seerr (Jellyseerr only).
    public func importJellyfinUsers(ids: [String]) async throws {
        try await client.perform(.post, "user/import-from-jellyfin", json: ["jellyfinUserIds": ids])
    }

    public func jobs() async throws -> [SeerrJob] { try await client.get("settings/jobs") }
    public func run(job id: String) async throws { try await client.perform(.post, "settings/jobs/\(id)/run") }
    public func cancel(job id: String) async throws { try await client.perform(.post, "settings/jobs/\(id)/cancel") }
}
