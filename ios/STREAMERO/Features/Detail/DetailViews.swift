import StreameroCore
import SwiftUI

// MARK: - Artist

struct ArtistView: View {
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppearanceStore.self) private var appearance
    @State private var showAllTracks = false
    @State private var showBio = false
    @State private var startingRadio = false

    var body: some View {
        AsyncContent(load: { try await app.api!.artist(id) }) { (page: ArtistPage) in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                    hero(page)
                    newReleases(page)
                    let top = showAllTracks ? page.topTracks : Array(page.topTracks.prefix(5))
                    if !top.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            if page.topTracks.count > 5 {
                                SectionHeader(title: "Top songs", action: (title: showAllTracks ? "Less" : "More", run: { withAnimation { showAllTracks.toggle() } }))
                            } else {
                                SectionHeader(title: "Top songs")
                            }
                            ForEach(Array(top.enumerated()), id: \.element.id) { i, t in
                                TrackRow(track: t, subtitle: t.artist.name, accessory: .plays) {
                                    player.play(tracks: page.topTracks, startAt: i, context: PlaybackContext(type: "artist", id: id, title: page.artist.name))
                                }
                            }
                        }
                    }
                    releaseShelf("Albums", page.releases.albums)
                    releaseShelf("Singles & EPs", page.releases.singles)
                    releaseShelf("Compilations", page.releases.compilations)
                    if !page.videos.isEmpty && appearance.features.videos {
                        Shelf(title: "Music videos", items: page.videos) { v in NavigationLink(value: Route.video(v.id)) { VideoCard(video: v) }.buttonStyle(.plain) }
                    }
                    if let bio = page.artist.bio, !bio.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            SectionHeader(title: "About")
                            Text(bio).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(showBio ? nil : 4)
                                .padding(.horizontal, Theme.Spacing.screen)
                                .onTapGesture { withAnimation { showBio.toggle() } }
                        }
                    }
                    if !page.related.isEmpty {
                        Shelf(title: "Fans also like", items: page.related) { a in NavigationLink(value: Route.artist(a.id)) { ArtistCard(artist: a) }.buttonStyle(.plain) }
                    }
                }
                .padding(.bottom, Theme.Spacing.xxl)
            }
            .ignoresSafeArea(edges: .top)
        }
        .streameroScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func hero(_ page: ArtistPage) -> some View {
        let followed = library.contains(.artist, id)
        let context = PlaybackContext(type: "artist", id: id, title: page.artist.name)
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            GeometryReader { geo in
                let minY = geo.frame(in: .global).minY
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(url: page.artist.artworkUrl, size: geo.size.width, cornerRadius: 0, placeholderSymbol: "music.mic")
                        .frame(width: geo.size.width, height: 420 + max(0, minY))
                        .clipped()
                    Theme.Gradients.scrim
                    LinearGradient(colors: [.clear, Theme.Palette.background], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.artist.name)
                            .font(Theme.Typography.media(52, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.4)
                        if let followers = page.artist.followerCount, followers > 0 {
                            Text("\(Format.compact(followers)) Followers").font(.system(size: 16)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                    .padding(.bottom, Theme.Spacing.s)
                }
                .offset(y: -max(0, minY)) // stretchy header on pull-down
            }
            .frame(height: 420)
            HStack(spacing: Theme.Spacing.s) {
                Button(followed ? "Following" : "Follow") {
                    library.toggle(.artist, id)
                    Haptics.toggle()
                }
                .buttonStyle(FollowButtonStyle(followed: followed))
                .accessibilityValue(followed ? "Following" : "Not following")
                Button { player.play(tracks: page.topTracks, context: context, shuffle: true) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true, height: 46))
                .disabled(page.topTracks.isEmpty)
                if appearance.features.radio {
                    Button { startRadio(page) } label: {
                        if startingRadio { ProgressView() } else { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true, height: 46))
                    .disabled(startingRadio)
                    .accessibilityHint("Plays a station of \(page.artist.name) and similar music")
                }
            }
            .padding(.horizontal, Theme.Spacing.screen)
        }
    }

    /// The newest releases as swipeable cards with a big white play button.
    @ViewBuilder private func newReleases(_ page: ArtistPage) -> some View {
        let releases = Array((page.releases.albums + page.releases.singles)
            .sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
            .prefix(3))
        if !releases.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeader(title: "New releases")
                TabView {
                    ForEach(releases) { album in
                        ReleaseCard(album: album).padding(.horizontal, Theme.Spacing.screen)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: releases.count > 1 ? .always : .never))
                .frame(height: 158)
            }
        }
    }

    private func startRadio(_ page: ArtistPage) {
        startingRadio = true
        Task {
            defer { startingRadio = false }
            var pool = page.topTracks
            if let genre = page.artist.genres.first, let more = try? await app.api?.tagTracks(kind: "genre", name: genre, limit: 60).items {
                let known = Set(pool.map(\.id))
                pool += more.filter { !known.contains($0.id) }
            }
            guard !pool.isEmpty else { return }
            player.play(tracks: pool.shuffled(), context: PlaybackContext(type: "radio", id: "artist-radio-\(id)", title: "\(page.artist.name) Radio"))
        }
    }

    @ViewBuilder private func releaseShelf(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            Shelf(title: title, items: albums) { a in NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a) }.buttonStyle(.plain) }
        }
    }
}

/// Filled accent pill while not following; outlined once followed.
struct FollowButtonStyle: ButtonStyle {
    let followed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(followed ? Theme.Palette.textPrimary : Theme.Palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(followed ? Color.clear : Theme.Palette.accent, in: Capsule())
            .overlay(Capsule().strokeBorder(followed ? Theme.Palette.textPrimary.opacity(0.85) : Color.clear, lineWidth: 1.2))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// "New releases" card: artwork, mono title, "EP • 2024 • 4 Songs" and a white play button.
struct ReleaseCard: View {
    let album: Album
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            NavigationLink(value: Route.album(album.id)) {
                HStack(spacing: Theme.Spacing.l) {
                    ArtworkView(url: album.artworkUrl, size: 92, cornerRadius: Theme.Radius.artwork, placeholderSymbol: "square.stack")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title).font(Theme.Typography.media(17, weight: .medium)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
                        Text([album.typeLabel, album.releaseYear, Format.count(album.trackCount, "Song")].compactMap { $0 }.joined(separator: " • "))
                            .font(.system(size: 14)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            PlayCircleButton(isPlaying: player.isPlaying && player.queue.context?.id == album.id, size: 60) {
                if player.queue.context?.id == album.id { player.togglePlayPause(); return }
                Task {
                    guard let page = try? await app.api?.album(album.id) else { return }
                    player.play(tracks: page.tracks, context: PlaybackContext(type: "album", id: album.id, title: album.title))
                }
            }
        }
        .padding(Theme.Spacing.l)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

// MARK: - Album

struct AlbumView: View {
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var tint: Color = Theme.Palette.surfaceHighlight

    var body: some View {
        AsyncContent(load: { try await app.api!.album(id) }) { (page: AlbumPage) in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    header(page)
                    let multiDisc = Set(page.tracks.compactMap(\.discNumber)).count > 1
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(page.tracks.enumerated()), id: \.element.id) { i, t in
                            if multiDisc, t.discNumber != (i > 0 ? page.tracks[i - 1].discNumber : nil) {
                                Text("Disc \(t.discNumber ?? 1)").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textTertiary)
                                    .padding(.horizontal, Theme.Spacing.screen).padding(.top, Theme.Spacing.m)
                            }
                            TrackRow(track: t, index: t.trackNumber ?? i + 1, showArtwork: false, subtitle: t.artist.name) {
                                player.play(tracks: page.tracks, startAt: i, context: PlaybackContext(type: "album", id: id, title: page.album.title))
                            }
                        }
                    }
                    Text(footer(page)).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textTertiary).padding(.horizontal, Theme.Spacing.screen)
                    if !page.moreByArtist.isEmpty {
                        Shelf(title: "More by \(page.album.artist.name)", items: page.moreByArtist) { a in NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a) }.buttonStyle(.plain) }
                    }
                    if !page.related.isEmpty {
                        Shelf(title: "You might also like", items: page.related) { a in NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a) }.buttonStyle(.plain) }
                    }
                }
                .padding(.bottom, Theme.Spacing.xxl)
            }
            .background(Theme.Gradients.artworkWash(tint).frame(height: 520).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea())
            .task(id: page.album.artworkUrl) {
                if let u = artworkURL(page.album.artworkUrl, points: 50), let img = await ImagePipeline.shared.image(for: u, pixelSize: 50), let c = img.averageColor {
                    withAnimation { tint = Color(c) }
                }
            }
        }
        .streameroScreen()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ page: AlbumPage) -> some View {
        let saved = library.contains(.album, id)
        let a = page.album
        let context = PlaybackContext(type: "album", id: id, title: a.title)
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            ArtworkView(url: a.artworkUrl, size: 240, cornerRadius: Theme.Radius.card, placeholderSymbol: "square.stack")
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.s)
            Text(a.title).font(Theme.Typography.media(26, weight: .heavy)).lineLimit(3)
            NavigationLink(value: Route.artist(a.artist.id)) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(a.artist.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.Palette.textPrimary)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Text([a.typeLabel, a.releaseYear].compactMap { $0 }.joined(separator: " • "))
                if a.explicit { ExplicitBadge() }
                if page.tracks.contains(where: \.supportsLossless) { QualityBadge(text: "Lossless", lossless: true) }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.l) {
                IconButton(systemName: saved ? "heart.fill" : "heart", label: saved ? "Remove from Your Library" : "Save to Your Library", size: 24, tint: saved ? Theme.Palette.accent : Theme.Palette.textPrimary) {
                    library.toggle(.album, id)
                    Haptics.toggle()
                    app.show(saved ? "Removed from Your Library" : "Added to Your Library", symbol: saved ? "minus.circle" : "checkmark.circle")
                }
                if AppearanceStore.shared.features.downloads {
                    IconButton(systemName: "arrow.down.circle", label: "Download album", size: 24, tint: Theme.Palette.textPrimary) {
                        Task { await downloads.download(tracks: page.tracks) }
                        app.show("Downloading \(a.title)", symbol: "arrow.down.circle")
                    }
                }
                Menu {
                    Button { player.playNext(page.tracks) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { player.addToQueue(page.tracks) } label: { Label("Add to queue", systemImage: "text.append") }
                    Button { app.addToPlaylist = AddToPlaylistRequest(tracks: page.tracks) } label: { Label("Add to playlist…", systemImage: "text.badge.plus") }
                    NavigationLink(value: Route.artist(a.artist.id)) { Label("Go to artist", systemImage: "music.mic") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.Palette.textPrimary).frame(width: 44, height: 44)
                }
                .accessibilityLabel("More")
                Spacer()
                IconButton(systemName: "shuffle", label: "Shuffle", size: 22, tint: player.queue.shuffle ? Theme.Palette.accent : Theme.Palette.textPrimary) {
                    player.play(tracks: page.tracks, context: context, shuffle: true)
                }
                PlayCircleButton(isPlaying: player.isPlaying && player.queue.context?.id == id, filledAccent: true) {
                    if player.queue.context?.id == id { player.togglePlayPause() } else { player.play(tracks: page.tracks, context: context) }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
    }

    private func footer(_ page: AlbumPage) -> String {
        var parts = [Format.count(page.album.trackCount, "song"), Format.longDuration(ms: page.album.durationMs)]
        if let label = page.album.label { parts.append("℗ \(label)") }
        if let date = page.album.releaseDate, let d = StreameroDate.parse(date) { parts.insert(d.formatted(date: .long, time: .omitted), at: 0) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Playlist

@MainActor
@Observable
final class PlaylistModel {
    var page: PlaylistPage?
    var error: Error?
    var editing = false

    func load(_ api: APIClient?, id: String) async {
        guard let api else { return }
        do { page = try await api.playlist(id, limit: 1000); error = nil } catch { self.error = error }
    }

    func move(_ api: APIClient?, from: IndexSet, to: Int) async {
        guard let api, var page, let source = from.first else { return }
        var items = page.items.items
        let item = items[source]
        items.move(fromOffsets: from, toOffset: to)
        page.items.items = items // optimistic
        self.page = page
        let dest = items.firstIndex { $0.itemId == item.itemId } ?? 0
        do { self.page = try await api.movePlaylistItem(page.playlist.id, itemId: item.itemId, toIndex: dest, expectedVersion: page.playlist.version) }
        catch { await load(api, id: page.playlist.id); self.error = error }
    }

    func remove(_ api: APIClient?, at offsets: IndexSet) async {
        guard let api, var page else { return }
        let ids = offsets.map { page.items.items[$0].itemId }
        page.items.items.remove(atOffsets: offsets)
        self.page = page
        do { self.page = try await api.removeFromPlaylist(page.playlist.id, itemIds: ids, expectedVersion: page.playlist.version) }
        catch { await load(api, id: page.playlist.id) }
    }
}

struct PlaylistView: View {
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(SyncCenter.self) private var sync
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var model = PlaylistModel()
    @State private var showEdit = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let page = model.page {
                content(page)
            } else if let e = model.error {
                ErrorStateView(error: e) { Task { await model.load(app.api, id: id) } }
            } else {
                SkeletonRows()
            }
        }
        .streameroScreen()
        .navigationBarTitleDisplayMode(.inline)
        // Collaborators' edits arrive through the 30 s sync.
        .task(id: sync.libraryRevision &+ sync.catalogRevision) { await model.load(app.api, id: id) }
        .refreshable { await model.load(app.api, id: id) }
    }

    private func content(_ page: PlaylistPage) -> some View {
        let tracks = page.items.items.compactMap(\.track)
        let p = page.playlist
        return List {
            Section {
                CollectionHeader(title: p.title, subtitle: [p.description, "\(p.isEditorial ? "STREAMERO" : (p.owner?.displayName ?? "")) • \(Format.count(p.itemCount, "song")), \(Format.longDuration(ms: p.durationMs))"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                                 artwork: p.artworkUrl, mosaic: p.mosaicUrls,
                                 onPlay: { player.play(tracks: tracks, context: PlaybackContext(type: "playlist", id: p.id, title: p.title)) },
                                 onShuffle: { player.play(tracks: tracks, context: PlaybackContext(type: "playlist", id: p.id, title: p.title), shuffle: true) },
                                 onDownload: { Task { await downloads.download(tracks: tracks) }; app.show("Downloading \(p.title)", symbol: "arrow.down.circle") },
                                 saved: p.isOwner ? nil : library.contains(.playlist, p.id),
                                 onSave: p.isOwner ? nil : { library.toggle(.playlist, p.id); Haptics.toggle() })
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            Section {
                ForEach(page.items.items) { item in
                    if let t = item.track {
                        TrackRow(track: t) {
                            let i = tracks.firstIndex(of: t) ?? 0
                            player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "playlist", id: p.id, title: p.title))
                        }
                    } else if let v = item.video {
                        NavigationLink(value: Route.video(v.id)) {
                            HStack { VideoThumbnail(url: v.thumbnailUrl, width: 86); Text(v.title).lineLimit(2) }.padding(.horizontal, Theme.Spacing.screen)
                        }
                    }
                }
                .onMove(perform: p.canEdit ? { from, to in Task { await model.move(app.api, from: from, to: to) } } : nil)
                .onDelete(perform: p.canEdit ? { offsets in Task { await model.remove(app.api, at: offsets) } } : nil)
                if page.items.items.isEmpty {
                    EmptyStateView(symbol: "music.note.list", title: "This playlist is empty", message: p.canEdit ? "Add songs from any track menu with “Add to playlist”." : "Nothing here yet.")
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(model.editing ? .active : .inactive))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if p.canEdit {
                    Button(model.editing ? "Done" : "Edit") { withAnimation { model.editing.toggle() } }
                }
                Menu {
                    if !p.isOwner {
                        let saved = library.contains(.playlist, p.id)
                        Button { library.toggle(.playlist, p.id) } label: { Label(saved ? "Remove from library" : "Save to library", systemImage: saved ? "minus.circle" : "plus.circle") }
                    }
                    if let share = p.shareUrl { ShareLink(item: share) { Label("Share", systemImage: "square.and.arrow.up") } }
                    if p.isOwner {
                        Button { showEdit = true } label: { Label("Edit details", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete playlist", systemImage: "trash") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showEdit, onDismiss: { Task { await model.load(app.api, id: id) } }) { EditPlaylistSheet(playlist: p) }
        .confirmationDialog("Delete “\(p.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete playlist", role: .destructive) {
                Task {
                    try? await app.api?.deletePlaylist(p.id)
                    app.show("Playlist deleted", symbol: "trash")
                    dismiss()
                }
            }
        } message: { Text("This can't be undone.") }
    }
}

struct EditPlaylistSheet: View {
    let playlist: Playlist
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var visibility = "private"
    @State private var collaborative = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $title)
                TextField("Description", text: $description, axis: .vertical)
                Picker("Visibility", selection: $visibility) {
                    Text("Private").tag("private")
                    Text("Anyone with the link").tag("unlisted")
                    Text("Public").tag("public")
                }
                Toggle("Collaborative", isOn: $collaborative)
                if let error { Text(error).foregroundStyle(Theme.Palette.danger) }
            }
            .navigationTitle("Edit playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            do {
                                _ = try await app.api?.updatePlaylist(playlist.id, patch: [
                                    "title": .string(title), "description": .string(description), "visibility": .string(visibility), "isCollaborative": .bool(collaborative),
                                ])
                                dismiss()
                            } catch { self.error = (error as? LocalizedError)?.errorDescription }
                        }
                    }
                    .disabled(title.isEmpty)
                }
            }
            .onAppear {
                title = playlist.title
                description = playlist.description ?? ""
                visibility = playlist.visibility
                collaborative = playlist.isCollaborative
            }
        }
    }
}

// MARK: - Mix & tags

struct MixView: View {
    let id: String
    let title: String
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        AsyncContent(load: { try await app.api!.mix(id) }) { (detail: MixDetail) in
            let tracks = detail.items.map(\.track)
            List {
                Section {
                    CollectionHeader(title: detail.mix.title, subtitle: detail.mix.description, artwork: nil, mosaic: detail.mix.artworkUrls ?? [], symbol: "sparkles",
                                     onPlay: { player.play(tracks: tracks, context: PlaybackContext(type: "mix", title: detail.mix.title)) },
                                     onShuffle: { player.play(tracks: tracks, context: PlaybackContext(type: "mix", title: detail.mix.title), shuffle: true) })
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Section {
                    ForEach(Array(detail.items.enumerated()), id: \.element.track.id) { i, item in
                        // Explainable recommendations: show why each track is here.
                        TrackRow(track: item.track, subtitle: "\(item.track.artist.name)\(item.reasons.first.map { " · \($0)" } ?? "")") {
                            player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "mix", title: detail.mix.title))
                        }
                    }
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
        .streameroScreen()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TagTracksView: View {
    let kind: String
    let name: String
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        AsyncContent(load: { try await app.api!.tagTracks(kind: kind, name: name, limit: 100).items }) { (tracks: [Track]) in
            List {
                Section {
                    CollectionHeader(title: name.capitalized, subtitle: kind == "mood" ? "Mood" : "Genre", artwork: nil, mosaic: Array(Set(tracks.compactMap(\.artworkUrl))).prefix(4).map { $0 }, symbol: "music.quarternote.3",
                                     onPlay: { player.play(tracks: tracks, context: PlaybackContext(type: "radio", title: name)) },
                                     onShuffle: { player.play(tracks: tracks, context: PlaybackContext(type: "radio", title: name), shuffle: true) })
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t) { player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "radio", title: name)) }
                    }
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
        .streameroScreen()
        .navigationBarTitleDisplayMode(.inline)
    }
}
