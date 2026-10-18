import StreameroCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var summary: LibrarySummary?
    @State private var showCreate = false

    var body: some View {
        List {
            Section {
                row(.likedSongs, "Liked Songs", "heart.fill", count: summary?.likedTracks ?? library.liked.count, gradient: true)
                row(.playlists, "Playlists", "music.note.list", count: summary.map { $0.ownPlaylists + $0.savedPlaylists })
                row(.savedAlbums, "Albums", "square.stack.fill", count: summary?.albums ?? library.albums.count)
                row(.followedArtists, "Artists", "music.mic", count: summary?.artists ?? library.artists.count)
                row(.downloads, "Downloaded", "arrow.down.circle.fill", count: downloads.records.filter { $0.state == .completed }.count)
                row(.recentlyPlayed, "Recently played", "clock.fill", count: nil)
                row(.likedVideos, "Liked videos", "play.rectangle.fill", count: summary?.likedVideos ?? library.videos.count)
            }
            .listRowBackground(Theme.Palette.background)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .streameroScreen()
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("New playlist")
            }
        }
        .sheet(isPresented: $showCreate) { CreatePlaylistSheet() }
        .task(id: library.revision) { summary = try? await app.api?.librarySummary() }
        .refreshable {
            await library.flush()
            summary = try? await app.api?.librarySummary()
        }
    }

    private func row(_ route: Route, _ title: String, _ symbol: String, count: Int?, gradient: Bool = false) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: Theme.Spacing.m) {
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(gradient ? AnyShapeStyle(Theme.Gradients.brand) : AnyShapeStyle(Theme.Palette.surfaceRaised))
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(gradient ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.Gradients.brand)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Typography.headline)
                    if let count { Text(Format.count(count, "item")).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary) }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Liked songs

struct LikedSongsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(NetworkMonitor.self) private var network
    @State private var tracks: [Track] = []
    @State private var nextOffset: Int? = 0
    @State private var sort = "recent"
    @State private var filter = ""
    @State private var error: Error?
    @State private var loading = false

    var body: some View {
        List {
            Section {
                CollectionHeader(title: "Liked Songs", subtitle: Format.count(tracks.count, "song"), artwork: nil, symbol: "heart.fill",
                                 onPlay: { play(shuffle: false) }, onShuffle: { play(shuffle: true) },
                                 onDownload: { Task { await downloads.download(tracks: tracks) }; app.show("Downloading \(tracks.count) songs", symbol: "arrow.down.circle") })
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            Section {
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, t in
                    TrackRow(track: t) { player.play(tracks: visible, startAt: i, context: PlaybackContext(type: "liked", title: "Liked Songs")) }
                        .onAppear { if t.id == tracks.last?.id { Task { await load(reset: false) } } }
                        .swipeActions { Button(role: .destructive) { app.toggleLike(t) } label: { Label("Unlike", systemImage: "heart.slash") } }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error, tracks.isEmpty { ErrorStateView(error: error) { Task { await load(reset: true) } } }
                if !loading && tracks.isEmpty && error == nil {
                    EmptyStateView(symbol: "heart", title: "Songs you like appear here", message: "Tap the heart on any song to save it to your library.")
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .streameroScreen()
        .searchable(text: $filter, prompt: "Filter liked songs")
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    Text("Recently added").tag("recent")
                    Text("Title").tag("title")
                    Text("Artist").tag("artist")
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
            .accessibilityLabel("Sort")
        }
        .task(id: "\(sort)|\(library.revision)") { await load(reset: true) }
    }

    /// Locally filtered (instant) on top of the server page; unliked songs disappear immediately.
    private var visible: [Track] {
        let base = tracks.filter { library.contains(.track, $0.id) }
        guard !filter.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(filter) || $0.artist.name.localizedCaseInsensitiveContains(filter) || ($0.album?.title.localizedCaseInsensitiveContains(filter) ?? false) }
    }

    private func load(reset: Bool) async {
        guard let api = app.api, !loading else { return }
        if !network.isOnline {
            tracks = downloads.completedTracks.filter { library.contains(.track, $0.id) }
            nextOffset = nil
            return
        }
        guard reset || nextOffset != nil else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await api.likedTracks(limit: 100, offset: reset ? 0 : (nextOffset ?? 0), sort: sort)
            tracks = reset ? page.items : tracks + page.items
            nextOffset = page.nextOffset
            error = nil
        } catch { self.error = error }
    }

    private func play(shuffle: Bool) {
        player.play(tracks: visible, context: PlaybackContext(type: "liked", title: "Liked Songs"), shuffle: shuffle)
    }
}

/// Header with artwork, title and play/shuffle/download actions for collections.
struct CollectionHeader: View {
    let title: String
    var subtitle: String?
    let artwork: URL?
    var mosaic: [URL] = []
    var symbol = "music.note.list"
    var onPlay: () -> Void
    var onShuffle: () -> Void
    var onDownload: (() -> Void)?
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Group {
                if artwork == nil && mosaic.isEmpty {
                    RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).fill(Theme.Gradients.brand)
                        .frame(width: 200, height: 200)
                        .overlay(Image(systemName: symbol).font(.system(size: 64, weight: .bold)).foregroundStyle(.white))
                } else if artwork == nil {
                    MosaicArtwork(urls: mosaic, size: 220)
                } else {
                    ArtworkView(url: artwork, size: 220, cornerRadius: Theme.Radius.l)
                }
            }
            .shadow(color: Theme.Shadow.artworkColor, radius: Theme.Shadow.artworkRadius, y: 12)
            VStack(spacing: 4) {
                Text(title).font(Theme.Typography.title).multilineTextAlignment(.center)
                if let subtitle { Text(subtitle).font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center) }
            }
            HStack(spacing: Theme.Spacing.xl) {
                if let onDownload { IconButton(systemName: "arrow.down.circle", label: "Download all", action: onDownload) }
                PlayCircleButton(action: onPlay)
                IconButton(systemName: "shuffle", label: "Shuffle", action: onShuffle)
            }
        }
        .padding(.vertical, Theme.Spacing.l)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Albums, artists, playlists

struct SavedAlbumsView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryStore.self) private var library
    @State private var sort = "recent"

    var body: some View {
        AsyncContent(load: { try await app.api?.savedAlbums(limit: 100, sort: sort).items ?? [] }) { (albums: [Album]) in
            let visible = albums.filter { library.contains(.album, $0.id) }
            if visible.isEmpty {
                EmptyStateView(symbol: "square.stack", title: "No saved albums", message: "Save albums to find them here quickly.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.l)], spacing: Theme.Spacing.xl) {
                        ForEach(visible) { a in NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a, size: 160) }.buttonStyle(.plain) }
                    }
                    .padding(Theme.Spacing.screen)
                }
            }
        }
        .id(sort)
        .streameroScreen()
        .navigationTitle("Albums")
        .toolbar {
            Picker("Sort", selection: $sort) {
                Text("Recent").tag("recent")
                Text("Title").tag("title")
                Text("Artist").tag("artist")
            }
        }
    }
}

struct FollowedArtistsView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        AsyncContent(load: { try await app.api?.followedArtists(limit: 200).items ?? [] }) { (artists: [Artist]) in
            if artists.isEmpty {
                EmptyStateView(symbol: "music.mic", title: "Follow artists", message: "Follow artists to see their new releases first.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: Theme.Spacing.l)], spacing: Theme.Spacing.xl) {
                        ForEach(artists) { a in NavigationLink(value: Route.artist(a.id)) { ArtistCard(artist: a, size: 110) }.buttonStyle(.plain) }
                    }
                    .padding(Theme.Spacing.screen)
                }
            }
        }
        .streameroScreen()
        .navigationTitle("Artists")
    }
}

struct PlaylistsListView: View {
    @Environment(AppModel.self) private var app
    @State private var showCreate = false
    @State private var reload = 0

    var body: some View {
        AsyncContent(load: { try await app.api?.myPlaylists(limit: 200).items ?? [] }) { (playlists: [Playlist]) in
            List {
                Button { showCreate = true } label: {
                    Label("New playlist", systemImage: "plus.square.fill").font(Theme.Typography.headline).foregroundStyle(Theme.Palette.accent)
                }
                .listRowBackground(Color.clear)
                ForEach(playlists) { p in
                    NavigationLink(value: Route.playlist(p.id)) {
                        HStack(spacing: Theme.Spacing.m) {
                            if p.artworkUrl == nil && !p.mosaicUrls.isEmpty { MosaicArtwork(urls: p.mosaicUrls, size: 56) } else { ArtworkView(url: p.artworkUrl, size: 56, placeholderSymbol: "music.note.list") }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(Theme.Typography.body.weight(.medium))
                                Text("\(p.isOwner ? "By you" : (p.owner?.displayName ?? "STREAMERO")) · \(Format.count(p.itemCount, "song"))")
                                    .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
        }
        .id(reload)
        .streameroScreen()
        .navigationTitle("Playlists")
        .sheet(isPresented: $showCreate, onDismiss: { reload += 1 }) { CreatePlaylistSheet() }
    }
}

struct CreatePlaylistSheet: View {
    var initialTracks: [Track] = []
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var visibility = "private"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name", text: $title)
                TextField("Description (optional)", text: $description, axis: .vertical).lineLimit(2...4)
                Picker("Visibility", selection: $visibility) {
                    Text("Private").tag("private")
                    Text("Anyone with the link").tag("unlisted")
                    Text("Public").tag("public")
                }
                if let error { Text(error).foregroundStyle(Theme.Palette.danger) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("New playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        guard let api = app.api else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let p = try await api.createPlaylist(title: title, description: description, visibility: visibility)
                if !initialTracks.isEmpty { _ = try await api.addToPlaylist(p.playlist.id, trackIds: initialTracks.map(\.id)) }
                Haptics.success()
                app.show("Created “\(title)”")
                dismiss()
            } catch { self.error = (error as? LocalizedError)?.errorDescription }
        }
    }
}

struct AddToPlaylistSheet: View {
    let tracks: [Track]
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            AsyncContent(load: { try await app.api?.myPlaylists(limit: 200).items.filter(\.canEdit) ?? [] }) { (playlists: [Playlist]) in
                List {
                    Button { showCreate = true } label: { Label("New playlist", systemImage: "plus") }
                    ForEach(playlists) { p in
                        Button {
                            Task {
                                do {
                                    _ = try await app.api?.addToPlaylist(p.id, trackIds: tracks.map(\.id))
                                    Haptics.success()
                                    app.show("Added to \(p.title)")
                                    dismiss()
                                } catch { app.show((error as? LocalizedError)?.errorDescription ?? "Could not add", symbol: "exclamationmark.triangle") }
                            }
                        } label: {
                            HStack {
                                ArtworkView(url: p.artworkUrl ?? p.mosaicUrls.first, size: 44, placeholderSymbol: "music.note.list")
                                Text(p.title).foregroundStyle(Theme.Palette.textPrimary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showCreate, onDismiss: { dismiss() }) { CreatePlaylistSheet(initialTracks: tracks) }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Downloads

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AudioPlayer.self) private var player
    @Environment(SettingsStore.self) private var settings
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Storage used").font(Theme.Typography.headline)
                        Text(Format.bytes(downloads.usedBytes)).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    if let free = freeSpace { Text("\(Format.bytes(free)) free").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textTertiary) }
                }
                Toggle("Download over cellular", isOn: $settings.values.downloadOverCellular)
                Picker("Download quality", selection: $settings.values.quality.download) {
                    ForEach(StreamProfile.allCases) { Text($0.title).tag($0) }
                }
            }
            let done = downloads.records.filter { $0.state == .completed }
            if !done.isEmpty {
                Section("Downloaded") {
                    let tracks = done.compactMap(\.track)
                    ForEach(done) { r in
                        Button {
                            if let t = r.track, let i = tracks.firstIndex(of: t) { player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "downloads", title: "Downloaded")) }
                        } label: { DownloadRow(record: r) }
                        .swipeActions { Button(role: .destructive) { downloads.delete(r) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
            let active = downloads.records.filter { $0.state != .completed }
            if !active.isEmpty {
                Section("In progress") {
                    ForEach(active) { r in
                        DownloadRow(record: r)
                            .swipeActions { Button(role: .destructive) { downloads.delete(r) } label: { Label("Cancel", systemImage: "xmark") } }
                    }
                }
            }
            if downloads.records.isEmpty {
                EmptyStateView(symbol: "arrow.down.circle", title: "No downloads yet", message: "Download songs, albums and playlists to listen without a connection.")
                    .listRowBackground(Color.clear)
            } else {
                Button("Remove all downloads", role: .destructive) { confirmClear = true }
            }
        }
        .streameroScreen()
        .navigationTitle("Downloaded")
        .confirmationDialog("Remove all downloads?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { downloads.deleteAll() }
        } message: { Text("Downloaded files are deleted from this device. You can download them again later.") }
        .task { await downloads.validateWithServer() }
    }

    private var freeSpace: Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

struct DownloadRow: View {
    let record: DownloadRecord
    @Environment(DownloadManager.self) private var downloads
    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ArtworkView(url: record.artworkURL, size: 48, placeholderSymbol: record.kind == "video" ? "play.rectangle" : "music.note")
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(Theme.Typography.body.weight(.medium)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    if record.lossless { QualityBadge(text: "Lossless", lossless: true) }
                    Text(statusText).font(Theme.Typography.caption).foregroundStyle(record.state == .failed ? Theme.Palette.danger : Theme.Palette.textSecondary)
                }
                if record.state == .downloading || record.state == .paused {
                    ProgressView(value: record.progress).tint(Theme.Palette.turquoise)
                }
            }
            Spacer()
            switch record.state {
            case .downloading: IconButton(systemName: "pause.circle", label: "Pause", size: 20) { downloads.pause(record) }
            case .paused: IconButton(systemName: "play.circle", label: "Resume", size: 20) { downloads.resume(record) }
            case .failed: IconButton(systemName: "arrow.clockwise.circle", label: "Retry", size: 20) { downloads.retry(record) }
            default: EmptyView()
            }
        }
    }

    private var statusText: String {
        switch record.state {
        case .queued: "Queued"
        case .downloading: "Downloading \(Int(record.progress * 100))%"
        case .paused: "Paused"
        case .verifying: "Verifying…"
        case .completed: record.isLicenseValid ? record.subtitle : "Connect to renew offline access"
        case .failed: record.errorMessage ?? "Failed"
        }
    }
}

// MARK: - Recently played, liked videos

struct RecentlyPlayedView: View {
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    var body: some View {
        AsyncContent(load: { try await app.api?.recentlyPlayed(limit: 100).items ?? [] }) { (tracks: [Track]) in
            if tracks.isEmpty {
                EmptyStateView(symbol: "clock", title: "Nothing played yet", message: "Your listening history appears here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                            TrackRow(track: t, subtitle: t.lastPlayedAt.map { "\(t.artist.name) · \($0.formatted(.relative(presentation: .named)))" }) {
                                player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "radio", title: "Recently played"))
                            }
                        }
                    }
                }
            }
        }
        .streameroScreen()
        .navigationTitle("Recently played")
    }
}

struct LikedVideosView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        AsyncContent(load: { try await app.api?.likedVideos(limit: 100).items ?? [] }) { (videos: [Video]) in
            if videos.isEmpty {
                EmptyStateView(symbol: "play.rectangle", title: "No liked videos", message: "Videos you like are saved here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Spacing.l)], spacing: Theme.Spacing.l) {
                        ForEach(videos) { v in NavigationLink(value: Route.video(v.id)) { VideoCard(video: v, width: 320) }.buttonStyle(.plain) }
                    }
                    .padding(Theme.Spacing.screen)
                }
            }
        }
        .streameroScreen()
        .navigationTitle("Liked videos")
    }
}
