import Foundation
import Observation
import StreameroCore
import SwiftData
import SwiftUI

enum DeepLink: Equatable {
    case verifyEmail(String)
    case resetPassword(String)
    case playlist(String)
}

/// Composition root: owns the services and the session lifecycle. Views receive it via the environment.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, onboarding, signedOut, signedIn }

    static private(set) var shared: AppModel?

    private(set) var phase: Phase = .launching
    private(set) var user: User?
    private(set) var api: APIClient?
    var serverURL: URL? { api?.baseURL }
    var pendingDeepLink: DeepLink?
    var isPlayerExpanded = false
    var toast: Toast?
    var selectedTab: AppTab = .home
    /// Tracks waiting for the "Add to playlist" sheet.
    var addToPlaylist: AddToPlaylistRequest?

    let settings: SettingsStore
    let network: NetworkMonitor
    let library: LibraryStore
    let events: EventReporter
    let player: AudioPlayer
    let downloads: DownloadManager
    let container: ModelContainer

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var message: String
        var symbol: String = "checkmark.circle.fill"
    }

    init() {
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
            ServerConfig.current = nil
            JSONFileStore.removeAll()
        }
        let container: ModelContainer
        do {
            container = try ModelContainer(for: DownloadRecord.self)
        } catch {
            // Corrupt store: fall back to an in-memory store rather than crashing; downloads re-validate later.
            container = try! ModelContainer(for: DownloadRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        self.container = container
        settings = SettingsStore()
        network = NetworkMonitor()
        library = LibraryStore()
        events = EventReporter()
        downloads = DownloadManager(container: container, settings: settings)
        player = AudioPlayer(settings: settings, network: network, events: events, library: library)
        network.onReconnect = { [weak self] in
            guard let self else { return }
            Task {
                await self.library.flush()
                await self.events.flush()
                await self.downloads.validateWithServer()
                self.player.networkReturned()
            }
        }
        AppModel.shared = self
        if let url = ServerConfig.current { configure(server: url) }
    }

    private func configure(server url: URL) {
        let store = KeychainTokenStore(service: "com.streamero.session.\(url.host ?? "server")")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let client = APIClient(baseURL: url, tokenStore: store, userAgent: "STREAMERO-iOS/\(version) (\(UIDevice.current.model))")
        api = client
        settings.attach(api: client)
        library.attach(api: client)
        events.attach(api: client)
        downloads.attach(api: client)
        player.attach(api: client, downloads: downloads)
        Task { await client.auth.setOnExpired { Task { @MainActor in AppModel.shared?.sessionExpired() } } }
    }

    /// Launch: decide between onboarding, sign-in and the main app. Works offline with cached state.
    func bootstrap() async {
        guard let api else { phase = .onboarding; return }
        guard await api.auth.isSignedIn else { phase = .signedOut; return }
        phase = .signedIn
        await loadAccount()
    }

    private func loadAccount() async {
        guard let api else { return }
        if let me = try? await api.me() {
            user = me
            settings.adopt(server: me.preferences, version: me.preferencesVersion)
        }
        await library.flush()
        await events.flush()
        await player.activateRestoredState()
        await downloads.validateWithServer()
    }

    /// Verifies the URL points at a STREAMERO server before saving it.
    func connect(to url: URL) async throws {
        var req = URLRequest(url: url.appendingPathComponent("healthz"), timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, String(data: data, encoding: .utf8)?.contains("ok") == true else {
            throw APIError.server(status: 0, code: "not_streamero", message: "That address doesn't look like a STREAMERO server.", details: nil)
        }
        ServerConfig.current = url
        configure(server: url)
        phase = await api?.auth.isSignedIn == true ? .signedIn : .signedOut
    }

    func changeServer() {
        Task { await signOut() }
        ServerConfig.current = nil
        api = nil
        phase = .onboarding
    }

    func didSignIn(_ session: Session) async {
        user = session.user
        phase = .signedIn
        await loadAccount()
    }

    func refreshUser() async {
        if let me = try? await api?.me() { user = me }
    }

    func signOut() async {
        player.stop()
        await api?.logout()
        library.reset()
        user = nil
        phase = api == nil ? .onboarding : .signedOut
    }

    func sessionExpired() {
        guard phase == .signedIn else { return }
        player.pause()
        user = nil
        phase = .signedOut
        show("Your session ended. Please sign in again.", symbol: "person.crop.circle.badge.exclamationmark")
    }

    func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        toast = Toast(message: message, symbol: symbol)
    }

    func handle(url: URL) {
        guard url.scheme == "streamero", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let token = comps.queryItems?.first { $0.name == "token" }?.value
        switch url.host {
        case "verify-email": if let token { pendingDeepLink = .verifyEmail(token) }
        case "reset-password": if let token { pendingDeepLink = .resetPassword(token) }
        case "playlist": if let id = url.pathComponents.dropFirst().first { pendingDeepLink = .playlist(id) }
        default: break
        }
    }

    func toggleLike(_ track: Track) {
        library.toggle(.track, track.id)
        Haptics.toggle()
        var t = track
        t.isLiked = library.contains(.track, track.id)
        player.updateTrackMetadata(t)
        player.updateNowPlaying()
    }
}

struct AddToPlaylistRequest: Identifiable {
    let id = UUID()
    var tracks: [Track]
}

enum AppTab: String, CaseIterable, Identifiable {
    case home, search, library, videos, profile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .library: "Library"
        case .videos: "Videos"
        case .profile: "Profile"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .library: "square.stack.fill"
        case .videos: "play.rectangle.fill"
        case .profile: "person.crop.circle.fill"
        }
    }
}
