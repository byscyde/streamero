import AVKit
import StreameroCore
import SwiftUI
import WebKit

struct VideosView: View {
    var body: some View {
        ScrollView {
            VideosContent().padding(.vertical, Theme.Spacing.l)
        }
        .streameroScreen()
        .navigationTitle("Videos")
        .toolbar { NavigationLink(value: Route.youtube) { Image(systemName: "play.tv") }.accessibilityLabel("YouTube discovery") }
    }
}

/// Video catalogue body, shared by the Videos screen and the Home "Videos" filter. Reloads on catalog sync.
struct VideosContent: View {
    @Environment(AppModel.self) private var app
    @Environment(SyncCenter.self) private var sync
    @State private var videos: [Video] = []
    @State private var continueWatching: [Video] = []
    @State private var nextOffset: Int? = 0
    @State private var error: Error?
    @State private var loading = false
    @State private var loaded = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if !continueWatching.isEmpty {
                Shelf(title: "Continue watching", items: continueWatching) { v in NavigationLink(value: Route.video(v.id)) { VideoCard(video: v) }.buttonStyle(.plain) }
            }
            if !videos.isEmpty {
                SectionHeader(title: "All videos")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Spacing.l)], spacing: Theme.Spacing.xl) {
                    ForEach(videos) { v in
                        NavigationLink(value: Route.video(v.id)) { VideoCard(video: v, width: 340) }
                            .buttonStyle(.plain)
                            .onAppear { if v.id == videos.last?.id { Task { await load(reset: false) } } }
                    }
                }
                .padding(.horizontal, Theme.Spacing.screen)
            } else if let error {
                ErrorStateView(error: error) { Task { await load(reset: true) } }
            } else if loading || !loaded {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 80)
            } else {
                EmptyStateView(symbol: "play.rectangle.on.rectangle", title: "No videos yet", message: "New videos will appear here automatically as soon as they are added.")
            }
        }
        .task(id: sync.catalogRevision &+ sync.libraryRevision) { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard let api = app.api, !loading, reset || nextOffset != nil else { return }
        loading = true
        defer { loading = false; loaded = true }
        do {
            let page = try await api.videos(limit: 30, offset: reset ? 0 : (nextOffset ?? 0))
            videos = reset ? page.items : videos + page.items
            nextOffset = page.nextOffset
            if reset { continueWatching = videos.filter { ($0.progress?.positionMs ?? 0) > 5000 && $0.progress?.completed == false } }
            error = nil
        } catch is CancellationError {
        } catch { if videos.isEmpty { self.error = error } }
    }
}

struct VideoDetailView: View {
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var audio
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var page: VideoPage?
    @State private var error: Error?
    @State private var playing: Video?

    var body: some View {
        ScrollView {
            if let page {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Button { playing = page.video } label: {
                        ZStack {
                            GeometryReader { geo in VideoThumbnail(url: page.video.thumbnailUrl, width: geo.size.width) }.aspectRatio(16 / 9, contentMode: .fit)
                            Image(systemName: "play.fill").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 76, height: 76).background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(page.video.title)")
                    .padding(.horizontal, Theme.Spacing.screen)

                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(page.video.title).font(Theme.Typography.title)
                        HStack(spacing: 6) {
                            if let a = page.video.artist { NavigationLink(value: Route.artist(a.id)) { Text(a.name).font(Theme.Typography.headline) } }
                            Text("· \(Format.time(page.video.duration))").foregroundStyle(Theme.Palette.textSecondary)
                            if page.video.explicit { ExplicitBadge() }
                        }
                        if !page.video.qualities.isEmpty {
                            HStack {
                                if let top = page.video.qualities.first { QualityBadge(text: top >= 1080 ? "HD 1080p" : "\(top)p") }
                                if !page.video.subtitles.isEmpty { QualityBadge(text: "CC \(page.video.subtitles.count)") }
                                if downloads.localVideo(id) != nil { QualityBadge(text: "Downloaded", lossless: true) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)

                    HStack(spacing: Theme.Spacing.m) {
                        let liked = library.contains(.video, id)
                        Button { library.toggle(.video, id); Haptics.toggle() } label: { Label(liked ? "Liked" : "Like", systemImage: liked ? "heart.fill" : "heart") }
                            .buttonStyle(SecondaryButtonStyle())
                        if page.video.hasAudioOnly {
                            Button { audio.playVideoAudio(page.video); app.isPlayerExpanded = true } label: { Label("Listen", systemImage: "headphones") }
                                .buttonStyle(SecondaryButtonStyle())
                                .accessibilityHint("Plays the audio version, which keeps playing in the background")
                        }
                        if page.video.downloadable, downloads.record("video", id) == nil {
                            Button { Task { await downloads.download(video: page.video) }; app.show("Downloading video", symbol: "arrow.down.circle") } label: { Image(systemName: "arrow.down.circle") }
                                .buttonStyle(SecondaryButtonStyle())
                                .accessibilityLabel("Download")
                        }
                        if let trackId = page.video.trackId {
                            Button {
                                Task { if let t = try? await app.api?.track(trackId) { audio.play(track: t) } }
                            } label: { Image(systemName: "music.note") }
                                .buttonStyle(SecondaryButtonStyle())
                                .accessibilityLabel("Play the song")
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)

                    if let d = page.video.description, !d.isEmpty {
                        Text(d).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary).padding(.horizontal, Theme.Spacing.screen)
                    }
                    if !page.related.isEmpty {
                        Shelf(title: "Up next", items: page.related) { v in NavigationLink(value: Route.video(v.id)) { VideoCard(video: v) }.buttonStyle(.plain) }
                    }
                }
                .padding(.vertical, Theme.Spacing.l)
            } else if let error {
                ErrorStateView(error: error) { Task { await load() } }
            } else {
                ProgressView().padding(.top, 120)
            }
        }
        .streameroScreen()
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { v in
            VideoPlayerScreen(video: v, upNext: page?.related ?? [])
        }
    }

    private func load() async {
        do { page = try await app.api?.video(id); error = nil } catch {
            if let v = downloads.record("video", id)?.video { page = VideoPage(video: v, related: []) } else { self.error = error }
        }
    }
}

struct VideoPlayerScreen: View {
    let video: Video
    var upNext: [Video]
    @Environment(AppModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var model: VideoPlaybackModel
    @State private var showOptions = false
    @State private var current: Video

    init(video: Video, upNext: [Video]) {
        self.video = video
        self.upNext = upNext
        _model = State(initialValue: VideoPlaybackModel(video: video))
        _current = State(initialValue: video)
    }

    private var useOverlay: Bool { !settings.values.preferNativeSubtitles || model.isOfflineCopy }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            SystemVideoPlayer(player: model.player, showsNativeSubtitles: !useOverlay)
                .ignoresSafeArea()
            if useOverlay {
                SubtitleOverlay(text: model.currentSubtitleText, scale: settings.values.subtitleScale, background: settings.values.subtitleBackground)
            }
            if let error = model.error {
                VStack {
                    ErrorStateView(error: error) { restart(current) }
                }
                .background(.black.opacity(0.85))
            }
            if model.ended, let next = upNext.first(where: { $0.id != current.id }), settings.values.autoplayVideos {
                UpNextCard(video: next) { restart(next) }
                    .padding(.bottom, 90)
            }
        }
        .overlay(alignment: .topLeading) {
            HStack {
                IconButton(systemName: "xmark", label: "Close", tint: .white) { close() }
                Spacer()
                IconButton(systemName: "slider.horizontal.3", label: "Video options", tint: .white) { showOptions = true }
            }
            .padding(.horizontal, Theme.Spacing.m)
        }
        .statusBarHidden()
        .task { await model.start(api: app.api, settings: settings, downloads: downloads, events: app.events) }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showOptions) { VideoOptionsSheet(model: model).presentationDetents([.medium, .large]) }
    }

    private func restart(_ v: Video) {
        model.stop()
        current = v
        model = VideoPlaybackModel(video: v)
        Task { await model.start(api: app.api, settings: settings, downloads: downloads, events: app.events) }
    }

    private func close() {
        model.stop()
        dismiss()
    }
}

struct UpNextCard: View {
    let video: Video
    let play: () -> Void
    var body: some View {
        Button(action: play) {
            HStack(spacing: Theme.Spacing.m) {
                VideoThumbnail(url: video.thumbnailUrl, width: 120)
                VStack(alignment: .leading) {
                    Text("UP NEXT").font(Theme.Typography.micro).foregroundStyle(Theme.Palette.turquoise)
                    Text(video.title).font(Theme.Typography.callout.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                }
                Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white)
            }
            .padding(Theme.Spacing.m)
            .glass()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.xl)
    }
}

struct VideoOptionsSheet: View {
    @Bindable var model: VideoPlaybackModel
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                if let s = model.stream, !s.qualities.isEmpty {
                    Section("Quality") {
                        Picker("Quality", selection: $model.quality) {
                            Text("Auto (adaptive)").tag(VideoPlaybackModel.QualityChoice.auto)
                            ForEach(s.qualities, id: \.height) { q in Text("Up to \(q.height)p").tag(VideoPlaybackModel.QualityChoice.max(q.height)) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                Section("Playback speed") {
                    Picker("Speed", selection: $model.rate) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Text(String(format: "%.2g×", r)).tag(Float(r)) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Subtitles") {
                    if let s = model.stream {
                        Picker("Track", selection: $model.selectedSubtitle) {
                            Text("Off").tag(VideoStream.Subtitle?.none)
                            ForEach(s.subtitles) { sub in
                                Text(sub.kind == "captions" ? "\(sub.label) (CC)" : sub.label).tag(Optional(sub))
                            }
                        }
                    }
                    Stepper(value: $model.subtitleOffset, in: -10...10, step: 0.25) {
                        Text("Sync offset: \(model.subtitleOffset, specifier: "%+.2f") s")
                    }
                    VStack(alignment: .leading) {
                        Text("Text size")
                        Slider(value: $settings.values.subtitleScale, in: 0.75...2, step: 0.25)
                    }
                    Toggle("Background for readability", isOn: $settings.values.subtitleBackground)
                    Toggle("Use system subtitle style", isOn: $settings.values.preferNativeSubtitles)
                    Text("System style follows Settings › Accessibility › Subtitles & Captioning and supports audio description tracks from the player menu.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textTertiary)
                }
                if model.isOfflineCopy {
                    Section { Label("Playing downloaded copy", systemImage: "arrow.down.circle.fill") }
                }
            }
            .navigationTitle("Video options")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - YouTube discovery (official API + official embedded player only)

struct YouTubeDiscoveryView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var results: YouTubeSearch?
    @State private var error: Error?
    @State private var selected: YouTubeResult?

    var body: some View {
        List {
            Section {
                TextField("Search YouTube", text: $query).onSubmit(search).submitLabel(.search)
            } footer: {
                Text("YouTube videos play in YouTube's official player while STREAMERO is open. They can't be downloaded or played in the background.")
            }
            if let error {
                Text((error as? APIError)?.code == "youtube_not_configured" ? "YouTube discovery isn't enabled on this server." : error.localizedDescription)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            if let results {
                Section(footer: Text(results.attribution)) {
                    ForEach(results.items) { r in
                        Button { selected = r } label: {
                            HStack(spacing: Theme.Spacing.m) {
                                VideoThumbnail(url: r.thumbnailUrl, width: 120)
                                VStack(alignment: .leading) {
                                    Text(r.title).font(Theme.Typography.callout.weight(.semibold)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
                                    if let c = r.channelTitle { Text(c).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .streameroScreen()
        .navigationTitle("YouTube")
        .sheet(item: $selected) { r in
            NavigationStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    YouTubeEmbed(videoId: r.videoId).aspectRatio(16 / 9, contentMode: .fit)
                    Text(r.title).font(Theme.Typography.headline).padding(.horizontal)
                    Link("Open in YouTube", destination: r.watchUrl).padding(.horizontal)
                    Spacer()
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } } }
            }
        }
    }

    private func search() {
        Task {
            do { results = try await app.api?.youtubeSearch(query); error = nil } catch { self.error = error }
        }
    }
}

/// Official YouTube IFrame embed. Branding, ads and controls are YouTube's; nothing is extracted.
struct YouTubeEmbed: UIViewRepresentable {
    let videoId: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .black
        let safeId = videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;background:#000;height:100%}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="https://www.youtube.com/embed/\(safeId)?playsinline=1&rel=0" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://streamero.app"))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
