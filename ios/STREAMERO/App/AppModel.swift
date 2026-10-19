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
    enum Phase: Equatable { case launching, signedOut, signedIn }

    static private(set) var shared: AppModel?

    private(set) var phase: Phase = .launching
    private(set) var user: User?
    private(set) var api: APIClient?
    var pendingDeepLink: DeepLink?
    var isPlayerExpanded = false
    var toast: Toast?
    var selectedTab: AppTab = .home
    /// Side menu with profile, settings and history (opened from the avatar).
    var isMenuOpen = false
    var showCreatePlaylist = false
    /// Tracks waiting for the "Add to playlist" sheet.
    var addToPlaylist: AddToPlaylistRequest?

    let settings: SettingsStore
    let network: NetworkMonitor
    let library: LibraryStore
    let events: EventReporter
    let player: AudioPlayer
    let downloads: DownloadManager
    let sync: SyncCenter
    let container: ModelContainer

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var message: String
        var symbol: String = "checkmark.circle.fill"
    }

    init() {
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
            JSONFileStore.removeAll()
            KeychainTokenStore(service: AppModel.keychainService).save(nil)
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
        sync = SyncCenter(library: library, events: events, downloads: downloads, network: network, player: player)
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
        configure(server: ServerConfig.url)
    }

    static let keychainService = "com.streamero.session"

    private func configure(server url: URL) {
        let store = KeychainTokenStore(service: AppModel.keychainService)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let client = APIClient(baseURL: url, tokenStore: store, userAgent: "STREAMERO-iOS/\(version) (\(UIDevice.current.model))")
        api = client
        settings.attach(api: client)
        library.attach(api: client)
        events.attach(api: client)
        downloads.attach(api: client)
        player.attach(api: client, downloads: downloads)
        sync.attach(api: client)
        Task { await client.auth.setOnExpired { Task { @MainActor in AppModel.shared?.sessionExpired() } } }
    }

    /// Launch: sign-in screen or the main app. Works offline with cached state.
    func bootstrap() async {
        guard let api else { phase = .signedOut; return }
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
        sync.start()
    }

    /// One navigation stack per tab, so the side menu can push screens and re-tapping a tab pops to root.
    var paths: [AppTab: NavigationPath] = [:]

    func pathBinding(_ tab: AppTab) -> Binding<NavigationPath> {
        Binding(get: { self.paths[tab] ?? NavigationPath() }, set: { self.paths[tab] = $0 })
    }

    func popToRoot(_ tab: AppTab) { paths[tab] = NavigationPath() }

    func navigate(to route: Route) {
        var path = paths[selectedTab] ?? NavigationPath()
        path.append(route)
        paths[selectedTab] = path
    }

    var avatarURL: URL? {
        user?.avatarUrl.flatMap { URL(string: $0, relativeTo: ServerConfig.url)?.absoluteURL }
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
        sync.reset()
        player.stop()
        await api?.logout()
        library.reset()
        user = nil
        phase = .signedOut
    }

    func sessionExpired() {
        guard phase == .signedIn else { return }
        sync.reset()
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
    case home, search, library, create
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .library: "Your Library"
        case .create: "Create"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .library: "books.vertical"
        case .create: "plus"
        }
    }
    var selectedSymbol: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .library: "books.vertical.fill"
        case .create: "plus"
        }
    }
}
