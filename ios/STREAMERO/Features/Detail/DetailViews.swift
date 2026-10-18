import StreameroCore
import SwiftUI

// MARK: - Artist

struct ArtistView: View {
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var showAllTracks = false
    @State private var showBio = false

    var body: some View {
        AsyncContent(load: { try await app.api!.artist(id) }) { (page: ArtistPage) in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                    hero(page)
                    let top = showAllTracks ? page.topTracks : Array(page.topTracks.prefix(5))
                    if !top.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            SectionHeader(title: "Popular")
                            ForEach(Array(top.enumerated()), id: \.element.id) { i, t in
                                TrackRow(track: t, index: i + 1, subtitle: t.album?.title) {
                                    player.play(tracks: page.topTracks, startAt: i, context: PlaybackContext(type: "artist", id: id, title: page.artist.name))
                                }
                            }
                            if page.topTracks.count > 5 {
                                Button(showAllTracks ? "Show less" : "Show more") { withAnimation { showAllTracks.toggle() } }
                                    .font(Theme.Typography.callout.weight(.semibold))
                                    .padding(.horizontal, Theme.Spacing.screen)
                            }
                        }
                    }
                    releaseShelf("Albums", page.releases.albums)
                    releaseShelf("Singles & EPs", page.releases.singles)
                    releaseShelf("Compilations", page.releases.compilations)
                    if !page.videos.isEmpty {
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
        }
        .streameroScreen()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hero(_ page: ArtistPage) -> some View {
        let followed = library.contains(.artist, id)
        return VStack(spacing: Theme.Spacing.l) {
            ArtworkView(url: page.artist.artworkUrl, size: 200, placeholderSymbol: "music.mic", circular: true)
                .shadow(color: Theme.Shadow.artworkColor, radius: Theme.Shadow.artworkRadius, y: 10)
            Text(page.artist.name).font(Theme.Typography.display).multilineTextAlignment(.center)
            if let followers = page.artist.followerCount, followers > 0 {
                Text(Format.count(followers, "follower")).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            HStack(spacing: Theme.Spacing.l) {
                Button(followed ? "Following" : "Follow") {
                    library.toggle(.artist, id)
                    Haptics.toggle()
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityValue(followed ? "Following" : "Not following")
                PlayCircleButton { player.play(tracks: page.topTracks, context: PlaybackContext(type: "artist", id: id, title: page.artist.name)) }
                IconButton(systemName: "shuffle", label: "Shuffle") {
                    player.play(tracks: page.topTracks, context: PlaybackContext(type: "artist", id: id, title: page.artist.name), shuffle: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.l)
    }

    @ViewBuilder private func releaseShelf(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            Shelf(title: title, items: albums) { a in NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a) }.buttonStyle(.plain) }
        }
    }
}

// MARK: - Album

struct AlbumView: View {
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var tint: Color = Theme.Palette.violet

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
                            TrackRow(track: t, index: t.trackNumber ?? i + 1, showArtwork: false, subtitle: t.artist.id == page.album.artist.id ? Format.time(t.duration) : "\(t.artist.name) · \(Format.time(t.duration))") {
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
        return VStack(spacing: Theme.Spacing.m) {
            ArtworkView(url: a.artworkUrl, size: 240, cornerRadius: Theme.Radius.l, placeholderSymbol: "square.stack")
                .shadow(color: Theme.Shadow.artworkColor, radius: Theme.Shadow.artworkRadius, y: 12)
            Text(a.title).font(Theme.Typography.title).multilineTextAlignment(.center)
            NavigationLink(value: Route.artist(a.artist.id)) { Text(a.artist.name).font(Theme.Typography.headline).foregroundStyle(Theme.Palette.accent) }
            HStack(spacing: 6) {
                Text([a.albumType.capitalized, a.releaseYear].compactMap { $0 }.joined(separator: " · "))
                if a.explicit { ExplicitBadge() }
                if page.tracks.contains(where: \.supportsLossless) { QualityBadge(text: "Lossless", lossless: true) }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.xl) {
                IconButton(systemName: saved ? "checkmark.circle.fill" : "plus.circle", label: saved ? "Remove from library" : "Save to library", tint: saved ? Theme.Palette.turquoise : Theme.Palette.textPrimary) {
                    library.toggle(.album, id)
                    Haptics.toggle()
                }
                IconButton(systemName: "arrow.down.circle", label: "Download album") {
                    Task { await downloads.download(tracks: page.tracks) }
                    app.show("Downloading \(a.title)", symbol: "arrow.down.circle")
                }
                PlayCircleButton { player.play(tracks: page.tracks, context: PlaybackContext(type: "album", id: id, title: a.title)) }
                IconButton(systemName: "shuffle", label: "Shuffle") { player.play(tracks: page.tracks, context: PlaybackContext(type: "album", id: id, title: a.title), shuffle: true) }
                Menu {
                    Button { player.playNext(page.tracks) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { player.addToQueue(page.tracks) } label: { Label("Add to queue", systemImage: "text.append") }
                    Button { app.addToPlaylist = AddToPlaylistRequest(tracks: page.tracks) } label: { Label("Add to playlist…", systemImage: "text.badge.plus") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("More")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.l)
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
        .task { await model.load(app.api, id: id) }
        .refreshable { await model.load(app.api, id: id) }
    }

    private func content(_ page: PlaylistPage) -> some View {
        let tracks = page.items.items.compactMap(\.track)
        let p = page.playlist
        return List {
            Section {
                CollectionHeader(title: p.title, subtitle: [p.description, "\(p.isEditorial ? "STREAMERO" : (p.owner?.displayName ?? "")) · \(Format.count(p.itemCount, "song")) · \(Format.longDuration(ms: p.durationMs))"].compactMap { $0 }.joined(separator: "\n"),
                                 artwork: p.artworkUrl, mosaic: p.mosaicUrls,
                                 onPlay: { player.play(tracks: tracks, context: PlaybackContext(type: "playlist", id: p.id, title: p.title)) },
                                 onShuffle: { player.play(tracks: tracks, context: PlaybackContext(type: "playlist", id: p.id, title: p.title), shuffle: true) },
                                 onDownload: { Task { await downloads.download(tracks: tracks) }; app.show("Downloading \(p.title)", symbol: "arrow.down.circle") })
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
