import Foundation
import LocalAuthentication
import Observation
import StreameroKit
import SwiftUI

/// App-wide state: configured services (persisted in the Keychain), app lock and transient toasts.
@MainActor
@Observable
final class AppState {
    static let keychainService = "com.scyde.streamero.services"

    private(set) var services: [ServiceInstance] = []
    var toast: Toast?
    var isLocked = false
    var appLockEnabled: Bool {
        didSet { UserDefaults.standard.set(appLockEnabled, forKey: "appLockEnabled") }
    }

    let deviceId: String
    let appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
    @ObservationIgnored var transport: HTTPTransport = URLSessionTransport()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var isError: Bool
    }

    init() {
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
            Keychain.save(nil, service: Self.keychainService)
            defaults.removeObject(forKey: "appLockEnabled")
        }
        if let id = defaults.string(forKey: "deviceId") {
            deviceId = id
        } else {
            deviceId = UUID().uuidString
            defaults.set(deviceId, forKey: "deviceId")
        }
        appLockEnabled = defaults.bool(forKey: "appLockEnabled")
        isLocked = appLockEnabled
        if let data = Keychain.load(service: Self.keychainService), let saved = try? JSONDecoder().decode([ServiceInstance].self, from: data) {
            services = saved
        } else {
            // First launch: one entry per service with the streamero.net addresses; only API keys are missing.
            services = ServiceKind.allCases.map { ServiceInstance(kind: $0, enabled: true) }
        }
    }

    // MARK: Services

    var configured: [ServiceInstance] { services.filter(\.isConfigured) }
    var hasAnyConfigured: Bool { !configured.isEmpty }

    func instances(_ kind: ServiceKind) -> [ServiceInstance] { configured.filter { $0.kind == kind } }
    func first(_ kind: ServiceKind) -> ServiceInstance? { instances(kind).first }

    func upsert(_ instance: ServiceInstance) {
        if let index = services.firstIndex(where: { $0.id == instance.id }) { services[index] = instance } else { services.append(instance) }
        persist()
    }

    func remove(_ id: UUID) {
        services.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        Keychain.save(try? JSONEncoder().encode(services), service: Self.keychainService)
    }

    func client(_ instance: ServiceInstance) throws -> ServiceClient {
        try ServiceClients.client(for: instance, deviceId: deviceId, appVersion: appVersion, transport: transport)
    }

    func sonarr(_ i: ServiceInstance) throws -> SonarrClient { SonarrClient(client: try client(i)) }
    func radarr(_ i: ServiceInstance) throws -> RadarrClient { RadarrClient(client: try client(i)) }
    func lidarr(_ i: ServiceInstance) throws -> LidarrClient { LidarrClient(client: try client(i)) }
    func prowlarr(_ i: ServiceInstance) throws -> ProwlarrClient { ProwlarrClient(client: try client(i)) }
    func bazarr(_ i: ServiceInstance) throws -> BazarrClient { BazarrClient(client: try client(i)) }
    func seerr(_ i: ServiceInstance) throws -> SeerrClient { SeerrClient(client: try client(i)) }
    func jellyfin(_ i: ServiceInstance) throws -> JellyfinClient { JellyfinClient(client: try client(i)) }

    // MARK: Feedback

    func show(_ message: String, error: Bool = false) {
        toast = Toast(message: message, isError: error)
    }

    /// Runs an action and reports success or the error as a toast.
    func perform(_ success: String? = nil, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                if let success { show(success) }
            } catch {
                show(Self.describe(error), error: true)
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: App lock

    func unlock() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false // no passcode on the device: nothing to unlock with
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Streamero") { ok, _ in
            Task { @MainActor in if ok { self.isLocked = false } }
        }
    }

    func lockIfNeeded() {
        if appLockEnabled { isLocked = true }
    }
}
