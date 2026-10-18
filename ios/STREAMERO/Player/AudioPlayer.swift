import AVFoundation
import MediaPlayer
import Observation
import StreameroCore
import UIKit

/// What the UI shows about the bytes actually being played (never claims lossless unless delivered).
struct PlaybackQualityInfo: Equatable {
    var profile: StreamProfile?
    var deliveredCodec: String?
    var deliveredBitrateKbps: Int?
    var deliveredLossless: Bool
    var source: SourceQuality?
    var isOffline: Bool

    var badge: String {
        if deliveredLossless { return "Lossless" }
        if let kbps = deliveredBitrateKbps { return "\((deliveredCodec ?? "AAC").uppercased()) \(kbps)" }
        return (deliveredCodec ?? "Stream").uppercased()
    }
}

/// The audio engine. Two AVQueuePlayer "decks": the active deck holds the current item plus the
/// pre-queued next item (gapless transitions); with crossfade enabled the idle deck starts the next
/// track early and the decks swap after an equal-power fade.
@MainActor
@Observable
final class AudioPlayer {
    // MARK: Observable state
    private(set) var queue = PlaybackQueue()
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedUntil: TimeInterval = 0
    private(set) var quality: PlaybackQualityInfo?
    private(set) var errorMessage: String?
    private(set) var sleepTimer: SleepTimerState?
    var playbackRate: Float = 1 { didSet { if isPlaying { activeDeck.player.rate = playbackRate } ; savePeriodically(force: true) } }
    var isScrubbing = false

    var current: Track? { queue.current?.track }
    var hasContent: Bool { queue.current != nil }

    // MARK: Dependencies
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let events: EventReporter
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private weak var downloads: DownloadManager?
    @ObservationIgnored private var api: APIClient?

    // MARK: Engine
    private final class Deck {
        let player = AVQueuePlayer()
        var entryForItem: [ObjectIdentifier: String] = [:] // AVPlayerItem -> queue entry id
        var observations: [NSKeyValueObservation] = []
    }

    @ObservationIgnored private let decks = [Deck(), Deck()]
    @ObservationIgnored private var activeIndex = 0
    private var activeDeck: Deck { decks[activeIndex] }
    private var idleDeck: Deck { decks[1 - activeIndex] }
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observedPlayer: AVQueuePlayer?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var preparedNextEntryId: String?
    @ObservationIgnored private var streamCache: [String: (url: URL, info: PlaybackQualityInfo, expires: Date)] = [:]
    @ObservationIgnored private var listening: ListeningSession?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var lastProgressSync = Date.distantPast
    @ObservationIgnored private var serverStateVersion = 0
    @ObservationIgnored private var stateSyncTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtworkURL: URL?
    @ObservationIgnored private var pendingResumePosition: TimeInterval?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []

    init(settings: SettingsStore, network: NetworkMonitor, events: EventReporter, library: LibraryStore) {
        self.settings = settings
        self.network = network
        self.events = events
        self.library = library
        for deck in decks {
            deck.player.automaticallyWaitsToMinimizeStalling = true
            deck.player.actionAtItemEnd = .advance
            deck.player.allowsExternalPlayback = true
        }
        configureAudioSession()
        observeSystemNotifications()
        configureRemoteCommands()
        attachObservers(to: activeDeck)
        restoreSnapshot()
    }

    func attach(api: APIClient?, downloads: DownloadManager?) {
        self.api = api
        self.downloads = downloads
        serverStateVersion = UserDefaults.standard.integer(forKey: "streamero.playbackStateVersion")
    }

    // MARK: - Public controls

    func play(tracks: [Track], startAt: Int = 0, context: PlaybackContext? = nil, shuffle: Bool? = nil) {
        guard !tracks.isEmpty else { return }
        finishListening(completed: false)
        queue.load(tracks, startAt: startAt, context: context, shuffle: shuffle)
        Haptics.tap()
        Task { await startCurrent(at: 0, autoplay: true) }
    }

    func play(track: Track, context: PlaybackContext? = nil) { play(tracks: [track], context: context) }

    /// Background-capable audio for a video the catalog prepared an audio rendition for.
    func playVideoAudio(_ video: Video) {
        let pseudo = Track(id: video.id, title: video.title, durationMs: video.durationMs, explicit: video.explicit,
                           artist: video.artist ?? ArtistRef(id: "", name: "Video"), artworkUrl: video.thumbnailUrl, downloadable: false)
        finishListening(completed: false)
        queue.load([pseudo], context: PlaybackContext(type: "video", id: video.id, title: video.title), shuffle: false)
        let resume = TimeInterval(video.progress?.positionMs ?? 0) / 1000
        Task { await startCurrent(at: resume, autoplay: true) }
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        guard hasContent else { return }
        activateSession()
        if activeDeck.player.currentItem == nil {
            Task { await startCurrent(at: position, autoplay: true) }
            return
        }
        activeDeck.player.playImmediately(atRate: playbackRate)
        listening?.resume()
        updateNowPlaying()
    }

    func pause() {
        fadeTask?.cancel()
        idleDeck.player.pause()
        activeDeck.player.pause()
        activeDeck.player.volume = 1
        listening?.pause()
        savePeriodically(force: true)
        updateNowPlaying()
    }

    func next() {
        guard let i = queue.nextIndex(userInitiated: true) else { stopAtEnd(); return }
        finishListening(completed: false)
        queue.jump(to: i)
        Task { await startCurrent(at: 0, autoplay: true) }
    }

    func previous() {
        let action = queue.previousAction(position: position)
        switch action {
        case .restartCurrent:
            seek(to: 0)
        case .moveTo(let i):
            finishListening(completed: false)
            queue.jump(to: i)
            Task { await startCurrent(at: 0, autoplay: true) }
        }
    }

    func jump(toEntry id: String) {
        finishListening(completed: false)
        queue.jump(toItemId: id)
        Task { await startCurrent(at: 0, autoplay: true) }
    }

    func seek(to time: TimeInterval) {
        let t = max(0, min(time, duration > 0 ? duration - 0.25 : time))
        position = t
        activeDeck.player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func skip(by seconds: TimeInterval) { seek(to: position + seconds) }

    func setShuffle(_ on: Bool) {
        queue.setShuffle(on)
        Haptics.selection()
        reprepareNext()
        savePeriodically(force: true)
        updateRemoteCommandState()
    }

    func cycleRepeat() {
        queue.repeatMode = queue.repeatMode.next
        Haptics.selection()
        reprepareNext()
        savePeriodically(force: true)
        updateRemoteCommandState()
    }

    func playNext(_ tracks: [Track]) {
        let wasEmpty = queue.isEmpty
        queue.playNext(tracks)
        if wasEmpty { Task { await startCurrent(at: 0, autoplay: true) } } else { reprepareNext() }
        Haptics.success()
        savePeriodically(force: true)
    }

    func addToQueue(_ tracks: [Track]) {
        let wasEmpty = queue.isEmpty
        queue.append(tracks)
        if wasEmpty { Task { await startCurrent(at: 0, autoplay: true) } } else { reprepareNext() }
        Haptics.success()
        savePeriodically(force: true)
    }

    func removeFromQueue(entryId: String) {
        let isCurrent = queue.current?.id == entryId
        queue.remove(itemId: entryId)
        if isCurrent { Task { await startCurrent(at: 0, autoplay: isPlaying) } } else { reprepareNext() }
        savePeriodically(force: true)
    }

    func moveInQueue(from: Int, to: Int) {
        queue.move(from: from, to: to)
        reprepareNext()
        savePeriodically(force: true)
    }

    func clearUpNext() {
        queue.clearUpNext()
        reprepareNext()
        savePeriodically(force: true)
    }

    func updateTrackMetadata(_ track: Track) { queue.updateTrack(track) }

    func setSleepTimer(_ option: SleepTimerOption?) {
        sleepTimer = option.map { SleepTimerState(option: $0) }
        Haptics.selection()
        if sleepTimer == nil { activeDeck.player.volume = 1 }
    }

    func stop() {
        finishListening(completed: false)
        fadeTask?.cancel()
        for d in decks { d.player.pause(); d.player.removeAllItems(); d.entryForItem = [:] }
        queue = PlaybackQueue()
        position = 0
        duration = 0
        quality = nil
        JSONFileStore.remove("playback")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Loading

    private func startCurrent(at start: TimeInterval, autoplay: Bool) async {
        guard let entry = queue.current else { return }
        fadeTask?.cancel()
        idleDeck.player.pause()
        idleDeck.player.removeAllItems()
        idleDeck.entryForItem = [:]
        errorMessage = nil
        isBuffering = true
        position = start
        duration = entry.track.duration
        updateNowPlaying()
        do {
            let (url, info) = try await resolve(entry)
            guard queue.current?.id == entry.id else { return } // user moved on while resolving
            let item = makeItem(url)
            let deck = activeDeck
            deck.player.pause()
            deck.player.removeAllItems()
            deck.entryForItem = [ObjectIdentifier(item): entry.id]
            deck.player.insert(item, after: nil)
            deck.player.volume = 1
            preparedNextEntryId = nil
            quality = info
            if start > 0.5 { await deck.player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
            if autoplay {
                activateSession()
                deck.player.playImmediately(atRate: playbackRate)
            }
            beginListening(entry)
            if !autoplay { listening?.pause() }
            retryCount = 0
            updateNowPlaying()
            savePeriodically(force: true)
            await prepareNext()
        } catch {
            isBuffering = false
            handleLoadFailure(error, entry: entry, at: start)
        }
    }

    private func makeItem(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = network.kind == .cellular ? 20 : 45
        item.audioTimePitchAlgorithm = .timeDomain // keeps pitch when playback speed changes
        return item
    }

    /// Local download first (offline, no data), otherwise a signed stream URL for the current network profile.
    private func resolve(_ entry: QueueItem, bypassCache: Bool = false) async throws -> (URL, PlaybackQualityInfo) {
        if entry.kind == .track, let local = downloads?.localFile(forTrack: entry.track.id) {
            return (local.url, PlaybackQualityInfo(profile: local.profile, deliveredCodec: local.codec, deliveredBitrateKbps: nil,
                                                   deliveredLossless: local.lossless, source: entry.track.sourceQuality, isOffline: true))
        }
        guard let api else { throw APIError.sessionExpired }
        guard network.isOnline else { throw APIError.network("offline") }
        if entry.kind == .videoAudio || queue.context?.type == "video" {
            let stream = try await api.videoStream(entry.track.id)
            guard let audio = stream.audioOnly else { throw APIError.server(status: 404, code: "no_audio", message: "This video has no audio-only version", details: nil) }
            return (audio.url, PlaybackQualityInfo(profile: .standard, deliveredCodec: "aac", deliveredBitrateKbps: audio.bitrateKbps, deliveredLossless: false, source: nil, isOffline: false))
        }
        let profile = settings.values.quality.profile(for: network.kind, lowDataMode: network.isConstrained)
        let key = "\(entry.track.id)#\(profile.rawValue)"
        if !bypassCache, let c = streamCache[key], c.expires > Date().addingTimeInterval(120) { return (c.url, c.info) }
        let s = try await api.trackStream(entry.track.id, profile: profile)
        let info = PlaybackQualityInfo(profile: StreamProfile(rawValue: s.profile), deliveredCodec: s.delivery.codec, deliveredBitrateKbps: s.delivery.bitrateKbps,
                                       deliveredLossless: s.delivery.lossless, source: s.source, isOffline: false)
        streamCache[key] = (s.url, info, s.expiresAt)
        return (s.url, info)
    }

    /// Gapless: enqueue the next track behind the current one on the active deck.
    private func prepareNext() async {
        guard settings.values.crossfadeSeconds < 0.5, settings.values.gapless else { return }
        guard sleepTimer?.option != .endOfTrack else { return }
        guard let n = queue.nextIndex(userInitiated: false) else { return }
        let entry = queue.items[n]
        guard preparedNextEntryId != entry.id || entry.id == queue.current?.id else { return }
        guard let (url, _) = try? await resolve(entry) else { return }
        let deck = activeDeck
        guard let currentItem = deck.player.currentItem else { return }
        // Drop a previously prepared item (queue edited) before inserting the new one.
        for item in deck.player.items() where item !== currentItem { deck.player.remove(item) }
        let item = makeItem(url)
        deck.entryForItem[ObjectIdentifier(item)] = entry.id
        if deck.player.canInsert(item, after: currentItem) {
            deck.player.insert(item, after: currentItem)
            preparedNextEntryId = entry.id
        }
    }

    private func reprepareNext() {
        preparedNextEntryId = nil
        Task { await prepareNext() }
    }

    private func handleLoadFailure(_ error: Error, entry: QueueItem, at position: TimeInterval) {
        if (error as? APIError)?.isOffline == true || !network.isOnline {
            errorMessage = "Waiting for network…"
            // Try the next downloaded track instead of stalling, if any.
            if let i = nextPlayableOfflineIndex() {
                queue.jump(to: i)
                Task { await startCurrent(at: 0, autoplay: true) }
            }
            return
        }
        if (error as? APIError)?.status == 404 {
            errorMessage = "“\(entry.track.title)” is no longer available"
            if queue.nextIndex(userInitiated: true) != nil { next() }
            return
        }
        retry(entry: entry, at: position)
    }

    private func nextPlayableOfflineIndex() -> Int? {
        guard let c = queue.currentIndex else { return nil }
        let order = Array(queue.items.indices.dropFirst(c + 1)) + (queue.repeatMode == .all ? Array(queue.items.indices.prefix(c)) : [])
        return order.first { downloads?.localFile(forTrack: queue.items[$0].track.id) != nil }
    }

    /// Exponential backoff with a freshly signed URL (the old one may have expired).
    private func retry(entry: QueueItem, at position: TimeInterval) {
        guard retryCount < 4 else { errorMessage = "Playback failed. Tap play to try again."; isPlaying = false; return }
        retryCount += 1
        let delay = pow(2, Double(retryCount - 1))
        errorMessage = "Reconnecting…"
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard queue.current?.id == entry.id else { return }
            streamCache = streamCache.filter { !$0.key.hasPrefix(entry.track.id) }
            await startCurrent(at: position, autoplay: true)
        }
    }

    // MARK: - Observation

    private func attachObservers(to deck: Deck) {
        if let observer = timeObserver, let p = observedPlayer { p.removeTimeObserver(observer) }
        for d in decks { d.observations = [] }
        observedPlayer = deck.player
        timeObserver = deck.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        deck.observations = [
            deck.player.observe(\.currentItem, options: [.old, .new]) { [weak self] player, change in
                let oldItem = change.oldValue ?? nil
                Task { @MainActor in self?.currentItemChanged(player, from: oldItem) }
            },
            deck.player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in self?.statusChanged(player) }
            },
        ]
    }

    private func statusChanged(_ player: AVQueuePlayer) {
        guard player === activeDeck.player else { return }
        isPlaying = player.timeControlStatus != .paused || fadeTask != nil
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if player.timeControlStatus == .playing { errorMessage = nil; listening?.resume() }
        if player.timeControlStatus == .paused { listening?.pause() }
        updateNowPlaying()
    }

    /// The active deck moved on by itself: the current item finished (gapless advance or end of queue).
    private func currentItemChanged(_ player: AVQueuePlayer, from oldItem: AVPlayerItem?) {
        guard player === activeDeck.player, fadeTask == nil else { return }
        guard oldItem != nil else { return }
        let newItem = player.currentItem
        if let newItem, let entryId = activeDeck.entryForItem[ObjectIdentifier(newItem)], entryId != queue.current?.id || queue.repeatMode == .one {
            finishListening(completed: true)
            if sleepTimer?.option == .endOfTrack { pause(); sleepTimer = nil; return }
            queue.advance(userInitiated: false)
            if queue.current?.id != entryId { queue.jump(toItemId: entryId) }
            preparedNextEntryId = nil
            position = 0
            duration = queue.current?.track.duration ?? 0
            if let entry = queue.current { beginListening(entry) }
            updateNowPlaying()
            savePeriodically(force: true)
            Task { await prepareNext() }
        } else if newItem == nil {
            // Reached the end with nothing queued (repeat off), or the next item was not ready in time.
            finishListening(completed: true)
            if sleepTimer?.option == .endOfTrack { sleepTimer = nil; stopAtEnd(); return }
            if let i = queue.nextIndex(userInitiated: false) {
                queue.jump(to: i)
                Task { await startCurrent(at: 0, autoplay: true) }
            } else {
                stopAtEnd()
            }
        }
    }

    private func stopAtEnd() {
        isPlaying = false
        position = 0
        if let first = queue.items.indices.first { queue.jump(to: first) }
        Task { await startCurrent(at: 0, autoplay: false) }
    }

    private func tick(_ time: CMTime) {
        let player = activeDeck.player
        guard let item = player.currentItem else { return }
        if !isScrubbing { position = max(0, time.seconds.isFinite ? time.seconds : 0) }
        let d = item.duration.seconds
        if d.isFinite, d > 0 { duration = d }
        if let range = item.loadedTimeRanges.last?.timeRangeValue { bufferedUntil = (range.start + range.duration).seconds }
        if item.status == .failed, let entry = queue.current {
            handleLoadFailure(item.error ?? APIError.network("failed"), entry: entry, at: position)
            return
        }
        checkCrossfade()
        checkSleepTimer()
        savePeriodically()
        syncLongTrackProgress()
    }

    // MARK: - Crossfade

    private func checkCrossfade() {
        let fade = settings.values.crossfadeSeconds
        guard fade >= 0.5, fadeTask == nil, isPlaying, duration > fade * 2, duration - position <= fade,
              sleepTimer?.option != .endOfTrack, let n = queue.nextIndex(userInitiated: false) else { return }
        let entry = queue.items[n]
        fadeTask = Task { [weak self] in await self?.crossfade(to: entry, over: fade) }
    }

    private func crossfade(to entry: QueueItem, over seconds: Double) async {
        guard let (url, info) = try? await resolve(entry) else { fadeTask = nil; return }
        let outgoing = activeDeck
        let incoming = idleDeck
        incoming.player.removeAllItems()
        let item = makeItem(url)
        incoming.entryForItem = [ObjectIdentifier(item): entry.id]
        incoming.player.insert(item, after: nil)
        incoming.player.volume = 0
        incoming.player.playImmediately(atRate: playbackRate)
        finishListening(completed: true)
        queue.advance(userInitiated: false)
        if queue.current?.id != entry.id { queue.jump(toItemId: entry.id) }
        quality = info
        position = 0
        duration = entry.track.duration
        beginListening(entry)
        updateNowPlaying()
        let steps = max(10, Int(seconds * 20))
        for s in 0...steps {
            if Task.isCancelled { break }
            let g = crossfadeGains(progress: Double(s) / Double(steps))
            outgoing.player.volume = g.outgoing
            incoming.player.volume = g.incoming
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000) / steps))
        }
        outgoing.player.pause()
        outgoing.player.removeAllItems()
        outgoing.entryForItem = [:]
        incoming.player.volume = 1
        activeIndex = 1 - activeIndex
        attachObservers(to: activeDeck)
        fadeTask = nil
        statusChanged(activeDeck.player)
        savePeriodically(force: true)
    }

    // MARK: - Sleep timer

    private func checkSleepTimer() {
        guard let timer = sleepTimer, case .minutes = timer.option else { return }
        if timer.isDue() {
            pause()
            sleepTimer = nil
            activeDeck.player.volume = 1
        } else {
            activeDeck.player.volume = timer.fadeVolume()
        }
    }

    // MARK: - Listening history

    private func beginListening(_ entry: QueueItem) {
        listening = ListeningSession(trackId: entry.track.id, context: queue.context)
        if isPlaying { listening?.resume() }
    }

    private func finishListening(completed: Bool) {
        guard var session = listening else { return }
        session.pause()
        if let event = session.finish(completed: completed, deviceId: DeviceIdentity.id) { events.record(event) }
        listening = nil
    }

    /// For long tracks (> 10 min, e.g. mixes or audiobooks) remember the position server-side for "Continue listening".
    private func syncLongTrackProgress() {
        guard let track = current, track.duration > 600, isPlaying, queue.context?.type != "video",
              Date().timeIntervalSince(lastProgressSync) > 30, let api else { return }
        lastProgressSync = Date()
        let id = track.id, pos = Int(position * 1000)
        Task { try? await api.saveTrackProgress(id, positionMs: pos) }
    }

    // MARK: - Persistence & sync

    private func snapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(queue: queue, positionMs: Int(position * 1000), playbackRate: Double(playbackRate))
    }

    private func savePeriodically(force: Bool = false) {
        guard hasContent, force || Date().timeIntervalSince(lastSave) > 10 else { return }
        lastSave = Date()
        let snap = snapshot()
        JSONFileStore.save(snap, to: "playback")
        stateSyncTask?.cancel()
        stateSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(force ? 5 : 20))
            await self?.pushState(snap)
        }
    }

    private func pushState(_ snap: PlaybackSnapshot) async {
        guard let api else { return }
        do {
            let r = try await api.putPlaybackState(snap, baseVersion: serverStateVersion, deviceId: DeviceIdentity.id)
            serverStateVersion = r.version
        } catch let e as APIError where e.code == "version_conflict" {
            // Another device played since; this device's state is newer locally, so overwrite on top of theirs.
            if case .server(_, _, _, let details) = e, let v = details?["version"]?.doubleValue {
                serverStateVersion = Int(v)
                _ = try? await api.putPlaybackState(snap, baseVersion: serverStateVersion, deviceId: DeviceIdentity.id).version
            }
        } catch {}
        UserDefaults.standard.set(serverStateVersion, forKey: "streamero.playbackStateVersion")
    }

    private func restoreSnapshot() {
        guard let snap = JSONFileStore.load(PlaybackSnapshot.self, from: "playback"), snap.queue.current != nil else { return }
        queue = snap.queue
        position = TimeInterval(snap.positionMs) / 1000
        duration = snap.queue.current?.track.duration ?? 0
        playbackRate = Float(snap.playbackRate)
        pendingResumePosition = position
    }

    /// After sign-in: load the restored item paused, or adopt a newer queue from another device.
    func activateRestoredState() async {
        if let api, let remote = try? await api.playbackState(), let state = remote.state,
           remote.deviceId != DeviceIdentity.id, state.savedAt > (JSONFileStore.load(PlaybackSnapshot.self, from: "playback")?.savedAt ?? .distantPast) {
            serverStateVersion = remote.version
            queue = state.queue
            position = TimeInterval(state.positionMs) / 1000
            pendingResumePosition = position
        } else if let api, let remote = try? await api.playbackState() {
            serverStateVersion = remote.version
        }
        guard hasContent, activeDeck.player.currentItem == nil else { return }
        await startCurrent(at: pendingResumePosition ?? 0, autoplay: false)
        pendingResumePosition = nil
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // .longFormAudio routes like Music/Podcasts (AirPlay 2 multi-room aware).
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handleInterruption(info) }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handleRouteChange(info) }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The media server crashed: every AVPlayer is invalid. Rebuild from the queue at the same position.
                self.configureAudioSession()
                Task { await self.startCurrent(at: self.position, autoplay: false) }
            }
        })
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, item === self.activeDeck.player.currentItem, let entry = self.queue.current else { return }
                self.handleLoadFailure(item.error ?? APIError.network("stalled"), entry: entry, at: self.position)
            }
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePeriodically(force: true) }
        })
    }

    @ObservationIgnored private var wasPlayingBeforeInterruption = false

    /// Phone calls, Siri, alarms: pause, and resume afterwards only when iOS says it is appropriate.
    /// Navigation prompts duck other audio automatically and do not interrupt long-form playback.
    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            listening?.pause()
            savePeriodically(force: true)
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if opts.contains(.shouldResume) && wasPlayingBeforeInterruption { resume() }
        @unknown default: break
        }
    }

    /// Unplugging headphones or a Bluetooth device disconnecting pauses playback (never blast the speaker).
    private func handleRouteChange(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable { pause() }
        updateNowPlaying()
    }

    func networkReturned() {
        guard let entry = queue.current, errorMessage != nil else { return }
        retryCount = 0
        _ = entry
        Task { await startCurrent(at: position, autoplay: true) }
    }

    // MARK: - Lock screen / Control Center / CarPlay

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlayPause() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
        c.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.setShuffle(e.shuffleType != .off) }
            return .success
        }
        c.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.queue.repeatMode = e.repeatType == .one ? .one : e.repeatType == .all ? .all : .off
                self.reprepareNext()
            }
            return .success
        }
        c.likeCommand.localizedTitle = "Like"
        c.likeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let t = self.current, self.queue.context?.type != "video" else { return }
                self.library.toggle(.track, t.id)
                self.updateRemoteCommandState()
            }
            return .success
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 2]
        c.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.playbackRate = e.playbackRate }
            return .success
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
    }

    private func updateRemoteCommandState() {
        let c = MPRemoteCommandCenter.shared()
        c.changeShuffleModeCommand.currentShuffleType = queue.shuffle ? .items : .off
        c.changeRepeatModeCommand.currentRepeatType = queue.repeatMode == .one ? .one : queue.repeatMode == .all ? .all : .off
        if let t = current { c.likeCommand.isActive = library.contains(.track, t.id) }
        c.nextTrackCommand.isEnabled = queue.nextIndex(userInitiated: true) != nil
    }

    func updateNowPlaying() {
        guard let track = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.items.count,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: queue.currentIndex ?? 0,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id,
        ]
        if let album = track.album?.title { info[MPMediaItemPropertyAlbumTitle] = album }
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork], nowPlayingArtworkURL == track.artworkUrl {
            info[MPMediaItemPropertyArtwork] = existing
        } else if let url = artworkURL(track.artworkUrl, points: 600) {
            nowPlayingArtworkURL = track.artworkUrl
            Task {
                guard let image = await ImagePipeline.shared.image(for: url, pixelSize: 1000), current?.id == track.id else { return }
                var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
                updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        updateRemoteCommandState()
    }
}
