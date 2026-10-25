import StreameroCore
import SwiftUI

@MainActor
@Observable
final class HomeModel {
    var feed: HomeFeed?
    var error: Error?
    var loading = false

    func load(api: APIClient?) async {
        guard let api, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let f = try await api.home()
            feed = f
            error = nil
            JSONFileStore.save(f, to: "home-cache")
        } catch is CancellationError {
        } catch {
            self.error = error
            if feed == nil { feed = JSONFileStore.load(HomeFeed.self, from: "home-cache") }
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(SyncCenter.self) private var sync
    @Environment(AppearanceStore.self) private var appearance
    @State private var model = HomeModel()
    @State private var filter = "All"
    @State private var showAllCaughtUp = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header
                chips
                AnnouncementBanner()
                if filter == "Videos" && appearance.features.videos {
                    VideosContent()
                } else {
                    content
                }
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
        .refreshable { await model.load(api: app.api) }
        .streameroScreen()
        .toolbar(.hidden, for: .navigationBar)
        .task { if model.feed == nil { await model.load(api: app.api) } }
        // New releases, edits and library changes from the 30 s sync appear without user action.
        .task(id: sync.catalogRevision &+ sync.libraryRevision) {
            if sync.catalogRevision + sync.libraryRevision > 0 { await model.load(api: app.api) }
        }
        .onChange(of: appearance.config.visibleHomeChips) { _, chips in
            if !chips.contains(filter) { filter = chips.first ?? "All" }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            AvatarButton(size: 44)
            if appearance.config.texts.homeGreeting {
                VStack(alignment: .leading, spacing: 1) {
                    Text(greeting).font(.system(size: 17)).foregroundStyle(Theme.Palette.textPrimary)
                    Text(firstName).font(.system(size: 17)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                }
            } else {
                Text("Home").font(Theme.Typography.screenTitle)
            }
            Spacer()
            Button { showAllCaughtUp = true } label: {
                Image(systemName: "bell")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if appearance.config.announcement.isVisible {
                            Circle().fill(Theme.Palette.accent).frame(width: 9, height: 9).offset(x: -9, y: 9)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Notifications")
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.top, Theme.Spacing.s)
        .alert(appearance.config.announcement.isVisible ? appearance.brand.appName : "You're all caught up", isPresented: $showAllCaughtUp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appearance.config.announcement.isVisible ? appearance.config.announcement.text : "New releases appear on Home automatically.")
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 5 || hour >= 18 { return "Good evening" }
        return hour < 12 ? "Good morning" : "Good afternoon"
    }

    private var firstName: String {
        let name = app.user?.displayName ?? ""
        return name.split(separator: " ").first.map(String.init) ?? "Listener"
    }

    private var chips: some View {
        HStack(spacing: Theme.Spacing.s) {
            ForEach(appearance.config.visibleHomeChips, id: \.self) { chip in
                Chip(title: chip, selected: filter == chip) { withAnimation(Theme.Motion.quick) { filter = chip } }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.screen)
    }

    // MARK: Sections

    @ViewBuilder private var content: some View {
        if let feed = model.feed {
            if feed.isCatalogEmpty {
                EmptyStateView(symbol: "music.note.house", title: "Nothing here yet", message: "New music and videos will appear here automatically as soon as they are added.")
            } else {
                ForEach(orderedSections(feed)) { section in
                    HomeSectionView(section: section)
                }
            }
        } else if let error = model.error {
            ErrorStateView(error: error) { Task { await model.load(api: app.api) } }
        } else {
            homeSkeleton
        }
    }

    /// Server sections in the admin-configured order; videos hidden on the Music chip or when disabled.
    private func orderedSections(_ feed: HomeFeed) -> [HomeSection] {
        var hidden = Set<String>()
        if filter == "Music" || !appearance.features.videos { hidden.insert("music_videos") }
        let sections = feed.sections.filter { !$0.items.isEmpty }
        let order = HomeSectionOrdering.order(kinds: sections.map(\.kind), by: appearance.config.home.sectionsOrder, hidden: hidden)
        return order.map { sections[$0] }
    }

    private var homeSkeleton: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Skeleton(width: 180, height: 22).padding(.horizontal, Theme.Spacing.screen)
                    HStack(spacing: Theme.Spacing.l) {
                        ForEach(0..<3, id: \.self) { _ in Skeleton(width: Theme.Size.card, height: Theme.Size.card, radius: Theme.Radius.card) }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                }
            }
        }
    }
}

/// One home/explore section, drawn according to what it contains: gradient genre chips, round artist
/// avatars, big album and playlist cards, track lists, mixes or videos.
struct HomeSectionView: View {
    let section: HomeSection
    var titleOverride: String?
    private var title: String { titleOverride ?? displayTitle }
    @Environment(AudioPlayer.self) private var player

    private var tracks: [Track] {
        section.items.compactMap { if case .track(let t) = $0 { return t }; return nil }
    }

    private var displayTitle: String {
        switch section.kind {
        case "favorite_artists", "top_artists": "Top artists"
        case "recently_added", "new_albums": "New albums"
        case "featured_playlists", "recommended_playlists": "Recommended playlists"
        case "trending", "popular_singles": "Popular singles"
        case "recently_played": "Jump back in"
        default: section.title
        }
    }

    private enum SectionShape { case genres, artists, albums, playlists, tracks, mixed }

    private var shape: SectionShape {
        let items = section.items
        if section.layout == "chips" || items.allSatisfy({ if case .genre = $0 { return true }; if case .mood = $0 { return true }; return false }) { return .genres }
        if section.layout == "list" || items.allSatisfy({ if case .track = $0 { return true }; return false }) { return .tracks }
        if items.allSatisfy({ if case .artist = $0 { return true }; return false }) { return .artists }
        if items.allSatisfy({ if case .album = $0 { return true }; return false }) { return .albums }
        if items.allSatisfy({ if case .playlist = $0 { return true }; return false }) { return .playlists }
        return .mixed
    }

    private var more: Route { .section(SectionRef(section: section)) }

    var body: some View {
        switch shape {
        case .genres:
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeader(title: section.kind == "moods" ? title : "Genres", more: .genres)
                GenreChipRow(names: section.items.compactMap { (item: HomeItem) -> (name: String, kind: String)? in
                    switch item {
                    case .genre(let g): return (name: g.name, kind: "genre")
                    case .mood(let g): return (name: g.name, kind: "mood")
                    default: return nil
                    }
                })
            }
        case .tracks:
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                SectionHeader(title: title, subtitle: section.subtitle, more: tracks.count > 5 ? more : nil)
                ForEach(Array(tracks.prefix(5).enumerated()), id: \.element.id) { i, t in
                    TrackRow(track: t, subtitle: t.resumePositionMs.map { "\(t.artist.name) • \(Format.time(TimeInterval($0) / 1000)) left" }) {
                        player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "radio", title: section.title))
                        if let resume = t.resumePositionMs { Task { try? await Task.sleep(for: .milliseconds(600)); player.seek(to: TimeInterval(resume) / 1000) } }
                    }
                }
            }
        case .artists:
            Shelf(title: title, more: more, items: section.items) { item in HomeItemCard(item: item, siblings: [], sectionTitle: section.title) }
        case .albums:
            Shelf(title: title, more: more, items: section.items) { item in
                if case .album(let a) = item {
                    NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a, size: Theme.Size.bigCard) }.buttonStyle(PressScaleStyle())
                }
            }
        case .playlists:
            Shelf(title: title, more: more, items: section.items) { item in
                if case .playlist(let p) = item {
                    NavigationLink(value: Route.playlist(p.id)) { BigPlaylistCard(playlist: p) }.buttonStyle(PressScaleStyle())
                }
            }
        case .mixed:
            Shelf(title: title, subtitle: section.subtitle, more: more, items: section.items) { item in
                HomeItemCard(item: item, siblings: tracks, sectionTitle: section.title)
            }
        }
    }
}

/// "More" target: every item of a section as a grid (or a track list).
struct SectionDetailView: View {
    let section: HomeSection
    @Environment(AudioPlayer.self) private var player

    private var tracks: [Track] { section.items.compactMap { if case .track(let t) = $0 { return t }; return nil } }

    var body: some View {
        ScrollView {
            if tracks.count == section.items.count {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t) { player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "radio", title: section.title)) }
                    }
                }
                .padding(.vertical, Theme.Spacing.m)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.l, alignment: .top)], spacing: Theme.Spacing.xl) {
                    ForEach(section.items) { item in HomeItemCard(item: item, siblings: tracks, sectionTitle: section.title, cardSize: 160) }
                }
                .padding(Theme.Spacing.screen)
            }
        }
        .streameroScreen()
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Gradient genre tile for grids (Search "Browse all", Explore, all genres).
struct CategoryTile: View {
    let title: String
    let index: Int
    var artwork: URL?
    var width: CGFloat? = nil
    var height: CGFloat = 96

    var body: some View {
        ZStack(alignment: .topLeading) {
            if AppearanceStore.shared.config.theme.genreGradients {
                Theme.Gradients.genre(title)
            } else {
                Theme.Palette.surfaceRaised
            }
            Text(title)
                .font(Theme.Typography.media(16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let artwork {
                ArtworkView(url: artwork, size: height * 0.62, cornerRadius: 6)
                    .rotationEffect(.degrees(20))
                    .shadow(color: .black.opacity(0.35), radius: 6)
                    .offset(x: 16, y: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

struct HomeItemCard: View {
    let item: HomeItem
    let siblings: [Track]
    let sectionTitle: String
    var cardSize: CGFloat = Theme.Size.card
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        switch item {
        case .track(let t):
            Button {
                let i = siblings.firstIndex(of: t) ?? 0
                player.play(tracks: siblings.isEmpty ? [t] : siblings, startAt: i, context: PlaybackContext(type: "radio", title: sectionTitle))
            } label: {
                MediaCard(title: t.title, subtitle: "Song • \(t.artist.name)", artwork: t.artworkUrl, size: cardSize)
            }
            .buttonStyle(PressScaleStyle())
            .contextMenu { TrackMenuItems(track: t) }
        case .album(let a):
            NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a, size: cardSize) }.buttonStyle(PressScaleStyle())
        case .artist(let a):
            NavigationLink(value: Route.artist(a.id)) { ArtistCard(artist: a, size: min(cardSize, Theme.Size.artistAvatar)) }.buttonStyle(PressScaleStyle())
        case .playlist(let p):
            NavigationLink(value: Route.playlist(p.id)) { PlaylistCard(playlist: p, size: cardSize) }.buttonStyle(PressScaleStyle())
        case .video(let v):
            if AppearanceStore.shared.features.videos {
                NavigationLink(value: Route.video(v.id)) { VideoCard(video: v) }.buttonStyle(PressScaleStyle())
            }
        case .mix(let m):
            NavigationLink(value: Route.mix(m.id, m.title)) { MixCard(mix: m, size: cardSize) }.buttonStyle(PressScaleStyle())
        case .genre(let g), .mood(let g):
            if let r = route(for: item) {
                NavigationLink(value: r) { CategoryTile(title: g.name.capitalized, index: 0, artwork: g.artworkUrl, width: cardSize, height: cardSize) }.buttonStyle(PressScaleStyle())
            }
        case .unknown:
            EmptyView()
        }
    }
}
