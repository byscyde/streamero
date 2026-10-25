import AVFoundation
import AVKit
import Combine
import StreameroCore
import SwiftUI

// MARK: - Mini player

/// Docked above the tab bar: artwork, mono title, "Artist • Album", heart, play/pause, thin progress line.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let track = player.current {
            HStack(spacing: Theme.Spacing.m) {
                ArtworkView(url: track.artworkUrl, size: 48, cornerRadius: Theme.Radius.artwork)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(Theme.Typography.media(16)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                    Text(player.errorMessage ?? subtitle(track))
                        .font(.system(size: 14))
                        .foregroundStyle(player.errorMessage == nil ? Theme.Palette.textSecondary : Theme.Palette.warning)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.queue.context?.type != "video" {
                    let liked = library.contains(.track, track.id)
                    IconButton(systemName: liked ? "heart.fill" : "heart", label: liked ? "Remove from Liked Songs" : "Add to Liked Songs",
                               size: 22, tint: liked ? Theme.Palette.accent : Theme.Palette.textPrimary) { app.toggleLike(track) }
                        .symbolEffect(.bounce, value: liked)
                }
                if player.isBuffering && player.isPlaying {
                    ProgressView().tint(Theme.Palette.textPrimary).frame(width: 44, height: 44)
                } else {
                    IconButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pause" : "Play", size: 24) { player.togglePlayPause() }
                }
            }
            .padding(.leading, Theme.Spacing.screen)
            .padding(.trailing, Theme.Spacing.s)
            .frame(height: Theme.Size.miniPlayerHeight)
            .background(Theme.Palette.surface)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.Palette.border.opacity(0.6))
                        Rectangle().fill(Theme.Palette.textPrimary)
                            .frame(width: player.duration > 0 ? geo.size.width * min(1, player.position / player.duration) : 0)
                    }
                }
                .frame(height: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.isPlayerExpanded = true }
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.height < -30 { app.isPlayerExpanded = true }
                else if v.translation.width < -60 { player.next() }
                else if v.translation.width > 60 { player.previous() }
            })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(track.title) by \(track.artist.name)")
            .accessibilityAction(named: "Open player") { app.isPlayerExpanded = true }
        }
    }

    private func subtitle(_ track: Track) -> String {
        [track.artist.name, track.album?.title].compactMap { $0 }.joined(separator: " • ")
    }
}

// MARK: - Full player

struct NowPlayingView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case song = "Song", lyrics = "Lyrics", upNext = "Up Next"
        var id: String { rawValue }
    }

    enum Sheet: String, Identifiable { case sleep, equalizer; var id: String { rawValue } }

    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tint: Color = Theme.Palette.surfaceRaised
    @State private var scrub: Double?
    @State private var tab: Tab = .song
    @State private var sheet: Sheet?
    @State private var dragOffset: CGFloat = 0

    private var tabs: [Tab] { Tab.allCases.filter { $0 != .lyrics || appearance.features.lyrics } }

    var body: some View {
        GeometryReader { geo in
            let artSize = max(120, min(geo.size.width - 48, geo.size.height * 0.40))
            ZStack {
                background
                if let track = player.current {
                    VStack(spacing: 0) {
                        topBar
                        switch tab {
                        case .song: songPanel(track, artSize: artSize)
                        case .lyrics: LyricsView().padding(.top, Theme.Spacing.s)
                        case .upNext: UpNextPanel(onGenre: openTag)
                        }
                    }
                    .task(id: track.artworkUrl) { await updateTint(track) }
                } else {
                    EmptyStateView(symbol: "music.note", title: "Nothing playing", message: "Pick something to listen to.")
                }
            }
            .offset(y: max(0, dragOffset))
            // Swipe down to close (only on the Song tab: Lyrics and Up Next scroll vertically).
            .gesture(DragGesture().onChanged { v in dragOffset = max(0, v.translation.height) }.onEnded { v in
                if v.translation.height > 140 { dismiss() }
                withAnimation(Theme.Motion.standard) { dragOffset = 0 }
            }, including: tab == .song ? .all : .subviews)
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .sleep: SleepTimerSheet().presentationDetents([.medium])
            case .equalizer: NavigationStack { EqualizerView(showsDone: true) }.presentationDetents([.large])
            }
        }
        .onAppear { if settings.values.showLyricsByDefault, appearance.features.lyrics, player.current?.hasLyrics == true { tab = .lyrics } }
        .onChange(of: appearance.features.lyrics) { _, on in if !on && tab == .lyrics { tab = .song } }
    }

    @ViewBuilder private var background: some View {
        if appearance.config.theme.playerStyle == .artwork {
            LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.35), Theme.Palette.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: tint)
        } else {
            Theme.Palette.background.ignoresSafeArea()
        }
    }

    // MARK: Top bar with segmented tabs

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            IconButton(systemName: "chevron.down", label: "Close player", size: 20) { dismiss() }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(tabs) { t in
                    Button { withAnimation(Theme.Motion.quick) { tab = t }; Haptics.selection() } label: {
                        Text(t.rawValue)
                            .font(.system(size: 15, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? Color.black : Theme.Palette.textSecondary)
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(tab == t ? Color.white : Color.clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
            trackMenu
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.top, Theme.Spacing.xs)
    }

    @ViewBuilder private var trackMenu: some View {
        if let t = player.current, player.queue.context?.type != "video" {
            Menu {
                TrackMenuItems(track: t)
                Divider()
                Menu("Playback speed") {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button { player.playbackRate = Float(r) } label: { Label("\(r, specifier: "%.2g")×", systemImage: player.playbackRate == Float(r) ? "checkmark" : "") }
                    }
                }
                Button { sheet = .sleep } label: { Label("Sleep timer", systemImage: "moon.zzz") }
                if appearance.features.equalizer {
                    Button { sheet = .equalizer } label: { Label("Equalizer", systemImage: "slider.vertical.3") }
                }
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.Palette.textPrimary).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More options")
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    // MARK: Song panel

    private func songPanel(_ track: Track, artSize: CGFloat) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer(minLength: 0)
            artwork(track, size: artSize)
            Spacer(minLength: 0)
            titleRow(track)
            genreChips(track)
            progress
            transport
            bottomBar
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.l)
    }

    private func artwork(_ track: Track, size: CGFloat) -> some View {
        ArtworkView(url: track.artworkUrl, size: size, cornerRadius: Theme.Radius.card)
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
            .scaleEffect(player.isPlaying || reduceMotion ? 1 : 0.88)
            .animation(Theme.Motion.expressive, value: player.isPlaying)
            .id(track.id)
            .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                if v.translation.width < -60 { player.next() } else if v.translation.width > 60 { player.previous() }
            })
            .onTapGesture(count: 2) { app.toggleLike(track) }
            .accessibilityLabel("Artwork for \(track.album?.title ?? track.title)")
    }

    private func titleRow(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s) {
            if player.queue.context?.type != "video" {
                let liked = library.contains(.track, track.id)
                IconButton(systemName: liked ? "heart.fill" : "heart", label: liked ? "Remove from Liked Songs" : "Add to Liked Songs", size: 24,
                           tint: liked ? Theme.Palette.accent : Theme.Palette.textPrimary) { app.toggleLike(track) }
                    .symbolEffect(.bounce, value: liked)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(track.title).font(Theme.Typography.media(24)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
                    if track.explicit { ExplicitBadge() }
                }
                Button {
                    guard !track.artist.id.isEmpty else { return }
                    dismiss()
                    app.navigate(to: .artist(track.artist.id))
                } label: {
                    Text([track.artist.name, track.album?.title].compactMap { $0 }.joined(separator: " • "))
                        .font(.system(size: 17)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            ShareLink(item: ServerConfig.url.appendingPathComponent("v1/tracks/\(track.id)"), subject: Text(track.title),
                      message: Text("\(track.title) — \(track.artist.name) on \(appearance.brand.appName)")) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 21)).foregroundStyle(Theme.Palette.textPrimary).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Share")
        }
    }

    @ViewBuilder private func genreChips(_ track: Track) -> some View {
        let tags = Array((track.genres.map { (name: $0, kind: "genre") } + track.moods.map { (name: $0, kind: "mood") }).prefix(6))
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                        Button { openTag(tag.kind, tag.name) } label: {
                            Text(tag.name.capitalized)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(Theme.Palette.textPrimary.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func openTag(_ kind: String, _ name: String) {
        dismiss()
        app.navigate(to: .tag(kind: kind, name: name))
    }

    private var progress: some View {
        VStack(spacing: 4) {
            let duration = max(player.duration, 1)
            Slider(value: Binding(get: { min(scrub ?? player.position, duration) }, set: { scrub = $0 }), in: 0...duration) { editing in
                player.isScrubbing = editing
                if !editing, let s = scrub { player.seek(to: s); scrub = nil }
            }
            .tint(Theme.Palette.textPrimary)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Format.time(player.position)) of \(Format.time(player.duration))")
            HStack {
                Text(Format.time(scrub ?? player.position))
                Spacer()
                if let q = player.quality {
                    QualityBadge(text: q.isOffline ? "Offline · \(q.badge)" : q.badge, lossless: q.deliveredLossless)
                        .accessibilityLabel("Quality \(q.badge)")
                }
                Spacer()
                Text(Format.time(player.duration))
            }
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var transport: some View {
        HStack {
            IconButton(systemName: "shuffle", label: player.queue.shuffle ? "Shuffle on" : "Shuffle off", size: 22,
                       tint: player.queue.shuffle ? Theme.Palette.accent : Theme.Palette.textPrimary) { player.setShuffle(!player.queue.shuffle) }
            Spacer()
            IconButton(systemName: "backward.end.fill", label: "Previous", size: 30) { player.previous() }
            Spacer()
            Button { player.togglePlayPause(); Haptics.tap() } label: {
                ZStack {
                    Circle().fill(Theme.Palette.playButton).frame(width: 80, height: 80)
                    if player.isBuffering && player.isPlaying {
                        ProgressView().tint(Theme.Palette.onPlayButton)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 32, weight: .bold)).foregroundStyle(Theme.Palette.onPlayButton)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            IconButton(systemName: "forward.end.fill", label: "Next", size: 30) { player.next() }
            Spacer()
            IconButton(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat", label: "Repeat \(player.queue.repeatMode.rawValue)", size: 22,
                       tint: player.queue.repeatMode == .off ? Theme.Palette.textPrimary : Theme.Palette.accent) { player.cycleRepeat() }
        }
    }

    /// Queue-add, output route pill and equaliser.
    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let t = player.current, player.queue.context?.type != "video" {
                IconButton(systemName: "text.badge.plus", label: "Add to playlist", size: 20) { app.addToPlaylist = AddToPlaylistRequest(tracks: [t]) }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            RoutePill()
            Spacer(minLength: 0)
            if let timer = player.sleepTimer {
                Button { sheet = .sleep } label: {
                    Label(timer.remaining().map { Format.time($0) } ?? "End of track", systemImage: "moon.zzz.fill").font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.Palette.accent)
            }
            if appearance.features.equalizer {
                IconButton(systemName: "slider.vertical.3", label: "Equalizer", size: 20,
                           tint: settings.values.equalizer.enabled ? Theme.Palette.accent : Theme.Palette.textPrimary) { sheet = .equalizer }
            }
        }
    }

    private func updateTint(_ track: Track) async {
        guard let u = artworkURL(track.artworkUrl, points: 50), let img = await ImagePipeline.shared.image(for: u, pixelSize: 50), let c = img.averageColor else { return }
        tint = Color(uiColor: c.darkened(0.25))
    }
}

/// Outline pill showing the current audio output; tapping opens the system AirPlay / Bluetooth picker.
struct RoutePill: View {
    @State private var name = RoutePill.currentName()
    @State private var symbol = RoutePill.currentSymbol()

    var body: some View {
        Label(name, systemImage: symbol)
            .font(.system(size: 14))
            .lineLimit(1)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .overlay(Capsule().strokeBorder(Theme.Palette.textPrimary.opacity(0.6), lineWidth: 1))
            .overlay { RoutePicker(invisible: true) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Audio output: \(name)")
            .accessibilityAddTraits(.isButton)
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
                name = RoutePill.currentName()
                symbol = RoutePill.currentSymbol()
            }
    }

    static func currentName() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "This iPhone"
    }

    static func currentSymbol() -> String {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType else { return "speaker.wave.2" }
        switch port {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "airpods"
        case .headphones, .usbAudio: return "headphones"
        case .airPlay: return "airplayaudio"
        case .carAudio: return "car"
        case .HDMI: return "tv"
        default: return "speaker.wave.2"
        }
    }
}

/// System AirPlay / Bluetooth route picker.
struct RoutePicker: UIViewRepresentable {
    var invisible = false
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = invisible ? .clear : UIColor.label
        v.activeTintColor = invisible ? .clear : Theme.Palette.accentUIColor
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Up Next

/// "Up Next" tab: the current track as a compact row, its genres, then the editable queue.
struct UpNextPanel: View {
    var onGenre: (String, String) -> Void
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        List {
            if let current = player.queue.current {
                Section {
                    HStack(spacing: Theme.Spacing.m) {
                        ArtworkView(url: current.track.artworkUrl, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(current.track.title).font(Theme.Typography.media(16)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                            Text([current.track.artist.name, current.track.album?.title].compactMap { $0 }.joined(separator: " • "))
                                .font(.system(size: 14)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        IconButton(systemName: "forward.end.fill", label: "Next", size: 20) { player.next() }
                        IconButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pause" : "Play", size: 22) { player.togglePlayPause() }
                    }
                    .listRowBackground(Theme.Palette.surface)
                    let tags = current.track.genres.map { (name: $0, kind: "genre") } + current.track.moods.map { (name: $0, kind: "mood") }
                    if !tags.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            Text("Related genres").font(Theme.Typography.section).foregroundStyle(Theme.Palette.textPrimary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Theme.Spacing.s) {
                                    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                                        Button { onGenre(tag.kind, tag.name) } label: {
                                            Text(tag.name.capitalized).font(.system(size: 14)).foregroundStyle(Theme.Palette.textPrimary)
                                                .padding(.horizontal, 14).frame(height: 34)
                                                .background(Theme.Palette.surfaceHighlight, in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, Theme.Spacing.s)
                        .listRowBackground(Color.clear)
                    }
                }
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(player.queue.upNext)) { entry in
                    Button { player.jump(toEntry: entry.id) } label: { QueueRow(entry: entry, isCurrent: false) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.Palette.separator)
                }
                .onMove { from, to in
                    let base = (player.queue.currentIndex ?? -1) + 1
                    guard let f = from.first else { return }
                    player.moveInQueue(from: base + f, to: base + (to > f ? to - 1 : to))
                }
                .onDelete { offsets in
                    let upcoming = Array(player.queue.upNext)
                    for i in offsets { player.removeFromQueue(entryId: upcoming[i].id) }
                }
                if player.queue.upNext.isEmpty {
                    Text("Nothing queued. Add songs with “Play next” or “Add to queue”.")
                        .font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textSecondary)
                        .listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    Text("Up Next").font(Theme.Typography.section).foregroundStyle(Theme.Palette.textPrimary).textCase(nil)
                    Spacer()
                    if !player.queue.upNext.isEmpty {
                        Button("Clear") { player.clearUpNext() }.buttonStyle(MorePillStyle()).textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

struct QueueRow: View {
    let entry: QueueItem
    let isCurrent: Bool
    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ArtworkView(url: entry.track.artworkUrl, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.track.title).font(Theme.Typography.media(16)).foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textPrimary).lineLimit(1)
                Text(entry.track.artist.name).font(.system(size: 14)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(Format.time(entry.track.duration)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
            Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(Theme.Palette.textPrimary).frame(width: 32)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Lyrics

/// "Lyrics" tab: time-synced lines on the player background; tap a line to seek.
struct LyricsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @State private var timeline: LyricsTimeline?
    @State private var attribution: LyricsResponse.Attribution?
    @State private var error: Error?
    @State private var userScrolling = false

    var body: some View {
        Group {
            if let timeline {
                lyrics(timeline)
            } else if let error {
                if (error as? APIError)?.isNotFound == true {
                    EmptyStateView(symbol: "quote.bubble", title: "No lyrics for this song", message: "Lyrics appear here when they're available for a track.")
                } else {
                    ErrorStateView(error: error) { Task { await load() } }
                }
            } else if player.current?.hasLyrics == false {
                EmptyStateView(symbol: "quote.bubble", title: "No lyrics for this song", message: "Lyrics appear here when they're available for a track.")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: player.current?.id) { await load() }
    }

    private func lyrics(_ t: LyricsTimeline) -> some View {
        let active = t.activeIndex(at: player.position)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    ForEach(t.lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(Theme.Typography.media(24, weight: .bold))
                            .foregroundStyle(lineColour(line, active: active, synced: t.synced))
                            .scaleEffect(line.id == active ? 1.03 : 1, anchor: .leading)
                            .animation(Theme.Motion.quick, value: active)
                            .id(line.id)
                            .onTapGesture { if t.synced { player.seek(to: line.start) } }
                            .accessibilityAddTraits(line.id == active ? .isSelected : [])
                    }
                    if let a = attribution, a.source != nil || a.license != nil {
                        Text([a.source.map { "Lyrics: \($0)" }, a.license].compactMap { $0 }.joined(separator: "\n"))
                            .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textTertiary).padding(.top, Theme.Spacing.xl)
                    }
                    if !t.synced {
                        Text("These lyrics aren't time-synced.").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .padding(Theme.Spacing.xl)
            }
            .onChange(of: active) { _, new in
                guard let new, !userScrolling else { return }
                withAnimation(Theme.Motion.standard) { proxy.scrollTo(new, anchor: .center) }
            }
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolling = true }.onEnded { _ in
                Task { try? await Task.sleep(for: .seconds(3)); userScrolling = false }
            })
        }
    }

    private func lineColour(_ line: LyricLine, active: Int?, synced: Bool) -> Color {
        guard synced, let active else { return .white }
        if line.id == active { return .white }
        return line.id < active ? .white.opacity(0.65) : .white.opacity(0.35)
    }

    private func load() async {
        guard let id = player.current?.id, let api = app.api, player.current?.hasLyrics != false else { return }
        timeline = nil
        error = nil
        do {
            let r = try await api.lyrics(trackId: id)
            timeline = LyricsTimeline(response: r)
            attribution = r.attribution
        } catch { self.error = error }
    }
}

// MARK: - Sleep timer

struct SleepTimerSheet: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(SleepTimerOption.presets) { option in
                    Button {
                        player.setSleepTimer(option)
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.title).foregroundStyle(Theme.Palette.textPrimary)
                            Spacer()
                            if player.sleepTimer?.option == option { Image(systemName: "checkmark").foregroundStyle(Theme.Palette.accent) }
                        }
                    }
                }
                if player.sleepTimer != nil {
                    Button("Turn off sleep timer", role: .destructive) { player.setSleepTimer(nil); dismiss() }
                }
            }
            .navigationTitle("Sleep timer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
