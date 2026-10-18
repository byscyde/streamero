import AVKit
import StreameroCore
import SwiftUI

// MARK: - Mini player

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let track = player.current {
            HStack(spacing: Theme.Spacing.m) {
                ArtworkView(url: track.artworkUrl, size: 44, cornerRadius: Theme.Radius.s)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(Theme.Typography.callout.weight(.semibold)).lineLimit(1)
                    Text(player.errorMessage ?? track.artist.name).font(Theme.Typography.caption).foregroundStyle(player.errorMessage == nil ? Theme.Palette.textSecondary : Theme.Palette.warning).lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.queue.context?.type != "video" {
                    IconButton(systemName: library.contains(.track, track.id) ? "heart.fill" : "heart", label: library.contains(.track, track.id) ? "Unlike" : "Like",
                               size: 18, tint: library.contains(.track, track.id) ? Theme.Palette.violet : Theme.Palette.textPrimary) { app.toggleLike(track) }
                }
                if player.isBuffering && player.isPlaying {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    IconButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pause" : "Play", size: 20) { player.togglePlayPause() }
                }
                IconButton(systemName: "forward.fill", label: "Next", size: 18) { player.next() }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: Theme.Size.miniPlayerHeight)
            .glass(cornerRadius: Theme.Radius.l)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule().fill(Theme.Gradients.brandHorizontal)
                        .frame(width: player.duration > 0 ? geo.size.width * player.position / player.duration : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, Theme.Spacing.m)
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
}

// MARK: - Full player

struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tint: Color = Theme.Palette.violet
    @State private var scrub: Double?
    @State private var panel: Panel?
    @State private var dragOffset: CGFloat = 0

    enum Panel: String, Identifiable { case queue, lyrics, sleep; var id: String { rawValue } }

    var body: some View {
        GeometryReader { geo in
            let artSize = min(geo.size.width - 48, geo.size.height * 0.42)
            ZStack {
                LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.25), Theme.Palette.background], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.8), value: tint)
                if let track = player.current {
                    VStack(spacing: Theme.Spacing.l) {
                        topBar
                        Spacer(minLength: 0)
                        artwork(track, size: artSize)
                        Spacer(minLength: 0)
                        titleRow(track)
                        progress
                        transport
                        bottomBar
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.l)
                    .task(id: track.artworkUrl) { await updateTint(track) }
                } else {
                    EmptyStateView(symbol: "music.note", title: "Nothing playing", message: "Pick something to listen to.")
                }
            }
            .offset(y: max(0, dragOffset))
            .gesture(DragGesture().onChanged { dragOffset = $0.translation.height }.onEnded { v in
                if v.translation.height > 140 { dismiss() }
                withAnimation(Theme.Motion.standard) { dragOffset = 0 }
            })
        }
        .sheet(item: $panel) { p in
            switch p {
            case .queue: QueueView().presentationDetents([.medium, .large])
            case .lyrics: LyricsView().presentationDetents([.large])
            case .sleep: SleepTimerSheet().presentationDetents([.medium])
            }
        }
        .onAppear { if settings.values.showLyricsByDefault, player.current?.hasLyrics == true { panel = .lyrics } }
    }

    private var topBar: some View {
        HStack {
            IconButton(systemName: "chevron.down", label: "Close player") { dismiss() }
            Spacer()
            VStack(spacing: 2) {
                Text("PLAYING FROM \(player.queue.context?.type.uppercased() ?? "QUEUE")").font(Theme.Typography.micro).tracking(1).foregroundStyle(Theme.Palette.textSecondary)
                if let title = player.queue.context?.title { Text(title).font(Theme.Typography.caption.weight(.semibold)).lineLimit(1) }
            }
            Spacer()
            trackMenu
        }
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
                Button { panel = .sleep } label: { Label("Sleep timer", systemImage: "moon.zzz") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More options")
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func artwork(_ track: Track, size: CGFloat) -> some View {
        ArtworkView(url: track.artworkUrl, size: size, cornerRadius: Theme.Radius.l)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
            .scaleEffect(player.isPlaying || reduceMotion ? 1 : 0.86)
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(track.title).font(Theme.Typography.title).lineLimit(1)
                    if track.explicit { ExplicitBadge() }
                }
                Button {
                    dismiss()
                    if !track.artist.id.isEmpty { app.selectedTab = .home }
                } label: {
                    Text(track.artist.name).font(Theme.Typography.headline).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if player.queue.context?.type != "video" {
                let liked = library.contains(.track, track.id)
                IconButton(systemName: liked ? "heart.fill" : "heart", label: liked ? "Unlike" : "Like", size: 24, tint: liked ? Theme.Palette.violet : Theme.Palette.textPrimary) { app.toggleLike(track) }
                    .symbolEffect(.bounce, value: liked)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 6) {
            let duration = max(player.duration, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.textPrimary.opacity(0.15)).frame(height: 4)
                Capsule().fill(Theme.Palette.textPrimary.opacity(0.25)).frame(width: nil, height: 4)
                    .mask(alignment: .leading) { GeometryReader { g in Rectangle().frame(width: g.size.width * min(1, player.bufferedUntil / duration)) } }
                Slider(value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }), in: 0...duration) { editing in
                    player.isScrubbing = editing
                    if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                }
                .tint(Theme.Palette.textPrimary)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(Format.time(player.position)) of \(Format.time(player.duration))")
            }
            HStack {
                Text(Format.time(scrub ?? player.position))
                Spacer()
                if let q = player.quality {
                    QualityBadge(text: q.isOffline ? "Offline · \(q.badge)" : q.badge, lossless: q.deliveredLossless)
                        .accessibilityLabel("Quality \(q.badge)")
                }
                Spacer()
                Text(Format.time(-(player.duration - (scrub ?? player.position))))
            }
            .font(Theme.Typography.mono)
            .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var transport: some View {
        HStack {
            IconButton(systemName: "shuffle", label: player.queue.shuffle ? "Shuffle on" : "Shuffle off", size: 20,
                       tint: player.queue.shuffle ? Theme.Palette.turquoise : Theme.Palette.textSecondary) { player.setShuffle(!player.queue.shuffle) }
            Spacer()
            IconButton(systemName: "backward.fill", label: "Previous", size: 30) { player.previous() }
            Spacer()
            Button { player.togglePlayPause(); Haptics.tap() } label: {
                ZStack {
                    Circle().fill(Theme.Palette.textPrimary).frame(width: 76, height: 76)
                    if player.isBuffering && player.isPlaying { ProgressView().tint(Theme.Palette.background) } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.Palette.background)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            IconButton(systemName: "forward.fill", label: "Next", size: 30) { player.next() }
            Spacer()
            IconButton(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat", label: "Repeat \(player.queue.repeatMode.rawValue)", size: 20,
                       tint: player.queue.repeatMode == .off ? Theme.Palette.textSecondary : Theme.Palette.turquoise) { player.cycleRepeat() }
        }
    }

    private var bottomBar: some View {
        HStack {
            IconButton(systemName: "quote.bubble", label: "Lyrics", size: 20, tint: player.current?.hasLyrics == true ? Theme.Palette.textPrimary : Theme.Palette.textTertiary) { panel = .lyrics }
                .disabled(player.current?.hasLyrics != true)
            Spacer()
            RoutePicker().frame(width: 44, height: 44).accessibilityLabel("Audio output")
            Spacer()
            if let timer = player.sleepTimer {
                Button { panel = .sleep } label: {
                    Label(timer.remaining().map { Format.time($0) } ?? "End of track", systemImage: "moon.zzz.fill").font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.Palette.turquoise)
                Spacer()
            }
            IconButton(systemName: "list.bullet", label: "Queue", size: 20) { panel = .queue }
        }
    }

    private func updateTint(_ track: Track) async {
        guard let u = artworkURL(track.artworkUrl, points: 50), let img = await ImagePipeline.shared.image(for: u, pixelSize: 50), let c = img.averageColor else { return }
        tint = Color(c)
    }
}

/// System AirPlay / Bluetooth route picker.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.label
        v.activeTintColor = UIColor(Theme.Palette.turquoise)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Queue

struct QueueView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.queue.current {
                    Section("Now playing") { QueueRow(entry: current, isCurrent: true) }
                }
                Section {
                    ForEach(Array(player.queue.upNext)) { entry in
                        Button { player.jump(toEntry: entry.id) } label: { QueueRow(entry: entry, isCurrent: false) }
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
                } header: {
                    HStack {
                        Text("Next up")
                        Spacer()
                        if !player.queue.upNext.isEmpty { Button("Clear") { player.clearUpNext() }.font(Theme.Typography.caption) }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct QueueRow: View {
    let entry: QueueItem
    let isCurrent: Bool
    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ArtworkView(url: entry.track.artworkUrl, size: 40, cornerRadius: Theme.Radius.s)
            VStack(alignment: .leading) {
                Text(entry.track.title).font(Theme.Typography.callout.weight(.medium)).foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textPrimary).lineLimit(1)
                Text(entry.track.artist.name).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(Format.time(entry.track.duration)).font(Theme.Typography.mono).foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}

// MARK: - Lyrics

struct LyricsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @State private var timeline: LyricsTimeline?
    @State private var attribution: LyricsResponse.Attribution?
    @State private var error: Error?
    @State private var userScrolling = false

    var body: some View {
        NavigationStack {
            Group {
                if let timeline {
                    lyrics(timeline)
                } else if let error {
                    if (error as? APIError)?.isNotFound == true {
                        EmptyStateView(symbol: "quote.bubble", title: "No lyrics for this song", message: "Lyrics appear here when they're available for a track.")
                    } else {
                        ErrorStateView(error: error) { Task { await load() } }
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.background)
            .navigationTitle(player.current?.title ?? "Lyrics")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: player.current?.id) { await load() }
    }

    private func lyrics(_ t: LyricsTimeline) -> some View {
        let active = t.activeIndex(at: player.position)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    ForEach(t.lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .foregroundStyle(!t.synced || line.id == active ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
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

    private func load() async {
        guard let id = player.current?.id, let api = app.api else { return }
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
