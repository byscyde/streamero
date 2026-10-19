import StreameroCore
import SwiftUI

/// "Your Library": filter chips, sort, list/grid, pinned Liked Songs and Downloaded, then playlists, albums and artists.
struct LibraryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case playlists = "Playlists", artists = "Artists", albums = "Albums", downloaded = "Downloaded"
        var id: String { rawValue }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case recents = "Recents", alphabetical = "Alphabetical", creator = "Creator"
        var id: String { rawValue }
    }

    private struct Entry: Identifiable {
        let id: String
        let route: Route
        let title: String
        let subtitle: String
        var artwork: URL?
        var mosaic: [URL] = []
        var circular = false
        var symbol = "music.note.list"
        let filter: Filter
        let creator: String
        let order: Int
    }

    @Environment(AppModel.self) private var app
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(SyncCenter.self) private var sync
    @State private var summary: LibrarySummary?
    @State private var playlists: [Playlist] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var filter: Filter?
    @State private var sort: Sort = .recents
    @State private var grid = false
    @State private var searching = false
    @State private var query = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    sortBar
                    if grid { gridContent } else { listContent }
                } header: { header }
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
        .streameroScreen()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(library.revision)|\(sync.libraryRevision)") { await load() }
        .refreshable {
            await library.flush()
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                AvatarButton()
                Text("Your Library").font(Theme.Typography.screenTitle)
                Spacer()
                Button { withAnimation(Theme.Motion.quick) { searching.toggle(); if !searching { query = "" } } } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .semibold))
                }
                .accessibilityLabel("Search in Your Library")
                Button { app.showCreatePlaylist = true } label: { Image(systemName: "plus").font(.system(size: 22, weight: .regular)) }
                    .accessibilityLabel("Create playlist")
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            if searching {
                TextField("Search in Your Library", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, Theme.Spacing.m)
                    .frame(height: 36)
                    .background(Theme.Palette.surfaceHighlight, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.s) {
                    if filter != nil {
                        Button { withAnimation(Theme.Motion.quick) { filter = nil } } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                                .frame(width: 32, height: 32)
                                .background(Theme.Palette.surfaceHighlight, in: Circle())
                        }
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .accessibilityLabel("Clear filter")
                    }
                    ForEach(Filter.allCases.filter { filter == nil || filter == $0 }) { f in
                        Chip(title: f.rawValue, selected: filter == f) { withAnimation(Theme.Motion.quick) { filter = filter == f ? nil : f } }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.m)
        .background(Theme.Palette.background)
    }

    private var sortBar: some View {
        HStack {
            Menu {
                Picker("Sort by", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
            } label: {
                Label(sort.rawValue, systemImage: "arrow.up.arrow.down").font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            Button { withAnimation(Theme.Motion.quick) { grid.toggle() } } label: {
                Image(systemName: grid ? "list.bullet" : "square.grid.2x2").font(.system(size: 15, weight: .semibold))
            }
            .accessibilityLabel(grid ? "Show as list" : "Show as grid")
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.vertical, Theme.Spacing.s)
    }

    // MARK: Content

    private var showsPinned: Bool { query.isEmpty && (filter == nil || filter == .playlists || filter == .downloaded) }
    private var likedCount: Int { summary?.likedTracks ?? library.liked.count }
    private var downloadedCount: Int { downloads.records.filter { $0.state == .completed }.count }

    @ViewBuilder private var listContent: some View {
        if showsPinned {
            if filter != .downloaded {
                NavigationLink(value: Route.likedSongs) {
                    HStack(spacing: Theme.Spacing.m) {
                        LikedSongsArtwork(size: 64)
                        pinnedText("Liked Songs", "Playlist • \(Format.count(likedCount, "song"))")
                    }
                    .padding(.horizontal, Theme.Spacing.screen).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
            NavigationLink(value: Route.downloads) {
                HStack(spacing: Theme.Spacing.m) {
                    PinnedSymbolArtwork(symbol: "arrow.down", colour: Color(hex: 0x006450), size: 64)
                    pinnedText("Downloaded", Format.count(downloadedCount, "item"))
                }
                .padding(.horizontal, Theme.Spacing.screen).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            if filter == nil {
                NavigationLink(value: Route.likedVideos) {
                    HStack(spacing: Theme.Spacing.m) {
                        PinnedSymbolArtwork(symbol: "play.rectangle.fill", colour: Color(hex: 0x8D67AB), size: 64)
                        pinnedText("Liked Videos", Format.count(summary?.likedVideos ?? library.videos.count, "video"))
                    }
                    .padding(.horizontal, Theme.Spacing.screen).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        ForEach(entries) { e in
            NavigationLink(value: e.route) {
                MediaRow(title: e.title, subtitle: e.subtitle, artwork: e.artwork, mosaic: e.mosaic, circular: e.circular, symbol: e.symbol, size: 64)
                    .padding(.vertical, 2)
            }
            .buttonStyle(RowButtonStyle())
        }
        if entries.isEmpty && !showsPinned {
            EmptyStateView(symbol: "books.vertical", title: "Nothing here yet", message: "Things you save, follow or download will appear here.")
        }
    }

    private var gridContent: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.m), GridItem(.flexible(), spacing: Theme.Spacing.m), GridItem(.flexible())], alignment: .leading, spacing: Theme.Spacing.l) {
            if showsPinned && filter != .downloaded {
                NavigationLink(value: Route.likedSongs) {
                    gridCell(artwork: { LikedSongsArtwork(size: $0) }, title: "Liked Songs", subtitle: "Playlist")
                }
                .buttonStyle(PressScaleStyle())
            }
            if showsPinned {
                NavigationLink(value: Route.downloads) {
                    gridCell(artwork: { PinnedSymbolArtwork(symbol: "arrow.down", colour: Color(hex: 0x006450), size: $0) }, title: "Downloaded", subtitle: Format.count(downloadedCount, "item"))
                }
                .buttonStyle(PressScaleStyle())
            }
            ForEach(entries) { e in
                NavigationLink(value: e.route) {
                    gridCell(artwork: { size in
                        if !e.mosaic.isEmpty && e.artwork == nil { MosaicArtwork(urls: e.mosaic, size: size) } else { ArtworkView(url: e.artwork, size: size, placeholderSymbol: e.symbol, circular: e.circular) }
                    }, title: e.title, subtitle: e.subtitle)
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
    }

    private func gridCell<A: View>(@ViewBuilder artwork: @escaping (CGFloat) -> A, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in artwork(geo.size.width) }.aspectRatio(1, contentMode: .fit)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
        }
    }

    private func pinnedText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 16)).foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: 4) {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.Palette.accent).rotationEffect(.degrees(45))
                Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        for (i, p) in playlists.enumerated() {
            let owner = p.isOwner ? (app.user?.displayName ?? "you") : (p.owner?.displayName ?? "STREAMERO")
            out.append(Entry(id: "p" + p.id, route: .playlist(p.id), title: p.title, subtitle: "Playlist • \(owner)", artwork: p.artworkUrl, mosaic: p.mosaicUrls,
                             filter: .playlists, creator: owner, order: i))
        }
        for (i, a) in albums.enumerated() where library.contains(.album, a.id) {
            out.append(Entry(id: "a" + a.id, route: .album(a.id), title: a.title, subtitle: "Album • \(a.artist.name)", artwork: a.artworkUrl, symbol: "square.stack",
                             filter: .albums, creator: a.artist.name, order: i))
        }
        for (i, a) in artists.enumerated() {
            out.append(Entry(id: "r" + a.id, route: .artist(a.id), title: a.name, subtitle: "Artist", artwork: a.artworkUrl, circular: true, symbol: "music.mic",
                             filter: .artists, creator: a.name, order: i))
        }
        if let filter {
            if filter == .downloaded {
                out = [] // downloads are per song/video; they are all reachable through the pinned "Downloaded" row
            } else {
                out = out.filter { $0.filter == filter }
            }
        }
        if !query.isEmpty { out = out.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) } }
        switch sort {
        case .recents: out.sort { $0.order == $1.order ? $0.title < $1.title : $0.order < $1.order }
        case .alphabetical: out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .creator: out.sort { $0.creator.localizedCaseInsensitiveCompare($1.creator) == .orderedAscending }
        }
        return out
    }

    private func load() async {
        guard let api = app.api else { return }
        async let s = try? api.librarySummary()
        async let p = try? api.myPlaylists(limit: 200).items
        async let a = try? api.savedAlbums(limit: 200).items
        async let r = try? api.followedArtists(limit: 200, sort: "recent").items
        let (summary, playlists, albums, artists) = await (s, p, a, r)
        if let summary { self.summary = summary }
        if let playlists { self.playlists = playlists }
        if let albums { self.albums = albums }
        if let artists { self.artists = artists }
    }
}

/// The Liked Songs cover: gradient square with a white heart.
struct LikedSongsArtwork: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous)
            .fill(Theme.Gradients.likedSongs)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "heart.fill").font(.system(size: size * 0.38)).foregroundStyle(.white))
    }
}

struct PinnedSymbolArtwork: View {
    let symbol: String
    let colour: Color
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous)
            .fill(colour.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.white))
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
                CollectionHeader(title: "Liked Songs", subtitle: Format.count(tracks.count, "song"), artwork: nil, symbol: "heart.fill", likedSongs: true,
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

/// Collection header: centred artwork over a colour wash taken from the artwork, left-aligned title,
/// then an action row with secondary actions on the left and shuffle + the green play button on the right.
struct CollectionHeader: View {
    let title: String
    var subtitle: String?
    let artwork: URL?
    var mosaic: [URL] = []
    var symbol = "music.note.list"
    var likedSongs = false
    var onPlay: () -> Void
    var onShuffle: () -> Void
    var onDownload: (() -> Void)?
    var saved: Bool?
    var onSave: (() -> Void)?
    @Environment(AudioPlayer.self) private var player
    @State private var tint = Theme.Palette.surfaceHighlight

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Group {
                if likedSongs {
                    LikedSongsArtwork(size: 230)
                } else if artwork == nil && mosaic.isEmpty {
                    PinnedSymbolArtwork(symbol: symbol, colour: Color(hex: 0x535353), size: 230)
                } else if artwork == nil {
                    MosaicArtwork(urls: mosaic, size: 230)
                } else {
                    ArtworkView(url: artwork, size: 230)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.s)

            Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(3)
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(4)
            }
            HStack(spacing: Theme.Spacing.l) {
                if let onSave, let saved {
                    IconButton(systemName: saved ? "checkmark.circle.fill" : "plus.circle", label: saved ? "Remove from Your Library" : "Save to Your Library",
                               size: 26, tint: saved ? Theme.Palette.accent : Theme.Palette.textSecondary, action: onSave)
                }
                if let onDownload {
                    IconButton(systemName: "arrow.down.circle", label: "Download", size: 26, tint: Theme.Palette.textSecondary, action: onDownload)
                }
                Spacer()
                IconButton(systemName: "shuffle", label: "Shuffle", size: 24, tint: player.queue.shuffle ? Theme.Palette.accent : Theme.Palette.textSecondary, action: onShuffle)
                PlayCircleButton(action: onPlay)
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.bottom, Theme.Spacing.s)
        .background(
            LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
                .padding(.top, -400) // extend the wash under the navigation bar
        )
        .task(id: artwork ?? mosaic.first) {
            if likedSongs { tint = Color(hex: 0x5038A0); return }
            if let u = artworkURL(artwork ?? mosaic.first, points: 50), let img = await ImagePipeline.shared.image(for: u, pixelSize: 50), let c = img.averageColor {
                withAnimation { tint = Color(c) }
            }
        }
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
