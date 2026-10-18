import AVFoundation
import AVKit
import Observation
import StreameroCore
import SwiftUI

/// Video session: HLS adaptive streaming via AVPlayer, manual quality caps, subtitles (native HLS
/// renditions or the custom overlay with size/offset), resume position and next-video handling.
@MainActor
@Observable
final class VideoPlaybackModel {
    enum QualityChoice: Hashable { case auto, max(Int) }

    let video: Video
    private(set) var stream: VideoStream?
    private(set) var error: Error?
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var ended = false
    private(set) var subtitleCues: SubtitleTimeline?
    var selectedSubtitle: VideoStream.Subtitle? { didSet { Task { await loadSubtitle() } } }
    var subtitleOffset: TimeInterval = 0
    var quality: QualityChoice = .auto { didSet { applyQuality() } }
    var rate: Float = 1 { didSet { if isPlaying { player.rate = rate } } }
    var isOfflineCopy = false

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endToken: NSObjectProtocol?
    @ObservationIgnored private var lastSaved: TimeInterval = -100
    @ObservationIgnored private weak var api: APIClient?
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var listening: ListeningSession?
    @ObservationIgnored private var events: EventReporter?

    init(video: Video) { self.video = video }

    func start(api: APIClient?, settings: SettingsStore, downloads: DownloadManager, events: EventReporter) async {
        self.api = api
        self.settings = settings
        self.events = events
        // The music player yields: video takes over the audio session while on screen.
        AppModel.shared?.player.pause()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let resume = video.progress.flatMap { $0.completed ? nil : TimeInterval($0.positionMs) / 1000 } ?? 0
        let item: AVPlayerItem
        if let local = downloads.localVideo(video.id) {
            isOfflineCopy = true
            item = AVPlayerItem(asset: AVURLAsset(url: local.asset))
            if let first = local.subtitles.first, let text = try? String(contentsOf: first, encoding: .utf8), settings.values.subtitlesEnabled {
                subtitleCues = SubtitleTimeline(cues: WebVTTParser.parse(text))
            }
        } else {
            guard let api else { return }
            do {
                let s = try await api.videoStream(video.id)
                stream = s
                item = AVPlayerItem(url: s.hlsUrl)
                autoSelectSubtitle(s)
            } catch {
                self.error = error
                return
            }
        }
        item.preferredForwardBufferDuration = 30
        player.replaceCurrentItem(with: item)
        player.allowsExternalPlayback = true
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                if item.status == .failed { self?.error = item.error ?? APIError.network("Playback failed") }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t) }
        }
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ended = true
                self?.saveProgress(force: true)
            }
        }
        if resume > 5 { await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
        listening = ListeningSession(trackId: video.id, context: PlaybackContext(type: "video", id: video.id))
        player.playImmediately(atRate: rate)
        listening?.resume()
    }

    private func autoSelectSubtitle(_ s: VideoStream) {
        guard let settings else { return }
        selectedSubtitle = StreameroCore.autoSelectSubtitle(s.subtitles, preferred: settings.values.subtitleLanguages, alwaysOn: settings.values.subtitlesEnabled,
                                                            language: \.language, isDefault: \.isDefault, forced: \.forced)
    }

    private func loadSubtitle() async {
        guard let sub = selectedSubtitle else { subtitleCues = nil; return }
        guard let (data, _) = try? await URLSession.shared.data(from: sub.vttUrl), let text = String(data: data, encoding: .utf8) else { return }
        subtitleCues = SubtitleTimeline(cues: WebVTTParser.parse(text))
    }

    /// Caps adaptive streaming at a resolution (manual quality); `.auto` lets AVPlayer adapt freely.
    private func applyQuality() {
        guard let item = player.currentItem else { return }
        switch quality {
        case .auto:
            item.preferredMaximumResolution = .zero
            item.preferredPeakBitRate = 0
        case .max(let h):
            item.preferredMaximumResolution = CGSize(width: CGFloat(h) * 16 / 9, height: CGFloat(h))
            if let q = stream?.qualities.first(where: { $0.height == h }) { item.preferredPeakBitRate = Double(q.bandwidth) * 1.1 }
        }
    }

    var currentSubtitleText: String? { subtitleCues?.text(at: position, offset: subtitleOffset) }

    private func tick(_ t: CMTime) {
        position = t.seconds.isFinite ? t.seconds : 0
        if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
        isPlaying = player.timeControlStatus != .paused
        if isPlaying { listening?.resume() } else { listening?.pause() }
        saveProgress()
    }

    /// Resume points sync every 10 s and on exit (last-write-wins on the server).
    func saveProgress(force: Bool = false) {
        guard force || abs(position - lastSaved) >= 10, duration > 0, let api else { return }
        lastSaved = position
        let id = video.id, pos = Int(position * 1000), dur = Int(duration * 1000)
        Task { try? await api.saveVideoProgress(id, positionMs: pos, durationMs: dur) }
    }

    func stop() {
        saveProgress(force: true)
        if var l = listening {
            l.pause()
            if let e = l.finish(completed: ended, deviceId: DeviceIdentity.id) { events?.record(e) }
            listening = nil
        }
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }
}

/// AVPlayerViewController gives system controls, Picture in Picture, AirPlay and the audio/subtitle
/// track menu for HLS renditions; the custom subtitle overlay sits on top when enabled.
struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsNativeSubtitles: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.updatesNowPlayingInfoCenter = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        // When our overlay renders subtitles, keep AVPlayer's own legible track off to avoid duplicates.
        if !showsNativeSubtitles, let item = player.currentItem,
           let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            item.select(nil, in: group)
        }
    }
}

struct SubtitleOverlay: View {
    let text: String?
    let scale: Double
    let background: Bool
    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 18 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black, radius: background ? 0 : 3)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(background ? Color.black.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 56)
                .padding(.horizontal, Theme.Spacing.xl)
                .allowsHitTesting(false)
                .accessibilityHidden(true) // VoiceOver users get the native legible track instead
        }
    }
}
