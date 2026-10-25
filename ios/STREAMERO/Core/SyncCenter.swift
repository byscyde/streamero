import BackgroundTasks
import Foundation
import Observation
import StreameroCore
import UIKit

/// Keeps the app in step with the server: every 30 s it asks `/v1/sync/state` whether the catalog or
/// the user's library changed, pushes pending offline edits and play events, and bumps revisions that
/// screens observe to reload. Runs while the app is open, and keeps running in the background while
/// music is playing (iOS keeps audio apps alive). When the app is suspended, iOS background app
/// refresh catches up opportunistically (the system decides when, typically every 15+ minutes).
@MainActor
@Observable
final class SyncCenter {
    static let interval: Duration = .seconds(30)
    static let backgroundTaskId = "com.scyde.streamero.sync"

    /// Screens use these as `.task(id:)` keys to reload when the server reports changes.
    private(set) var catalogRevision = 0
    private(set) var libraryRevision = 0
    private(set) var lastSuccess: Date?

    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let events: EventReporter
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let player: AudioPlayer
    @ObservationIgnored private let appearance: AppearanceStore
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var last: SyncState?
    @ObservationIgnored private var lastDownloadCheck = Date.distantPast
    @ObservationIgnored private var running = false

    init(library: LibraryStore, events: EventReporter, downloads: DownloadManager, network: NetworkMonitor, player: AudioPlayer, appearance: AppearanceStore) {
        self.appearance = appearance
        self.library = library
        self.events = events
        self.downloads = downloads
        self.network = network
        self.player = player
    }

    func attach(api: APIClient?) { self.api = api }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: SyncCenter.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Foreground: always poll. Background: keep polling only while audio keeps the app alive.
    func scenePhaseChanged(active: Bool) {
        if active {
            start()
            Task { await syncNow() }
        } else if !player.isPlaying {
            stop()
            scheduleBackgroundRefresh()
        }
    }

    func reset() {
        stop()
        last = nil
    }

    func syncNow() async {
        guard let api, !running, network.isOnline, await api.auth.isSignedIn else { return }
        running = true
        defer { running = false }
        await library.flush() // push pending likes/saves first so the next state reflects them
        await events.flush()
        guard let state = try? await api.syncState() else { return }
        let diff = SyncDiff(previous: last, current: state)
        last = state
        lastSuccess = Date()
        if diff.libraryChanged {
            await library.refresh()
            libraryRevision += 1
        }
        if diff.catalogChanged { catalogRevision += 1 }
        // Admin appearance edits (colours, texts, feature switches) arrive within one poll.
        await appearance.syncReported(configVersion: state.configVersion, api: api)
        if Date().timeIntervalSince(lastDownloadCheck) > 600 {
            lastDownloadCheck = Date()
            await downloads.validateWithServer()
        }
    }

    // MARK: Background app refresh

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                guard let sync = AppModel.shared?.sync else { refresh.setTaskCompleted(success: false); return }
                sync.scheduleBackgroundRefresh()
                let work = Task { await sync.syncNow() }
                refresh.expirationHandler = { work.cancel() }
                await work.value
                refresh.setTaskCompleted(success: true)
            }
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
