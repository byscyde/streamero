import Foundation

/// Reachability, version and health of one service, for the dashboard.
public struct ProbeResult: Sendable, Identifiable {
    public var id: UUID { instance.id }
    public var instance: ServiceInstance
    public var version: String?
    public var issues: [HealthIssue]
    public var error: String?
    public var isOnline: Bool { error == nil }
    public var worstSeverity: HealthSeverity { error != nil ? .error : (issues.map(\.severity).max() ?? .ok) }
}

public enum ServiceProbe {
    public static func probe(_ instance: ServiceInstance, client: ServiceClient) async -> ProbeResult {
        var result = ProbeResult(instance: instance, version: nil, issues: [], error: nil)
        do {
            switch instance.kind {
            case .jellyfin:
                let info = try await JellyfinClient(client: client).systemInfo()
                result.version = info.version
                if info.hasPendingRestart == true { result.issues.append(HealthIssue(service: instance.name, severity: .warning, message: "Restart required to finish an update or configuration change")) }
                if info.hasUpdateAvailable == true { result.issues.append(HealthIssue(service: instance.name, severity: .notice, message: "A Jellyfin update is available")) }
            case .seerr:
                let status = try await SeerrClient(client: client).status()
                result.version = status.version
                if status.updateAvailable == true { result.issues.append(HealthIssue(service: instance.name, severity: .notice, message: "An update is available")) }
            case .bazarr:
                let bazarr = BazarrClient(client: client)
                result.version = try await bazarr.status().bazarrVersion
                let health = (try? await bazarr.health()) ?? []
                result.issues = health.compactMap { item in
                    item.issue.map { HealthIssue(service: instance.name, severity: .warning, message: [item.object, $0].compactMap { $0 }.joined(separator: ": ")) }
                }
            case .sonarr, .radarr, .lidarr, .prowlarr:
                let arr = GenericArr(client: client)
                result.version = try await arr.systemStatus().version
                result.issues = ((try? await arr.health()) ?? []).map { HealthIssue(service: instance.name, health: $0) }
            }
        } catch {
            result.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return result
    }
}

/// Any *arr app, for the endpoints they all share.
public struct GenericArr: ArrService {
    public let client: ServiceClient
    public init(client: ServiceClient) { self.client = client }
}
