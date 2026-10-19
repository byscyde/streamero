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
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", music = "Music", videos = "Videos"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(SyncCenter.self) private var sync
    @State private var model = HomeModel()
    @State private var filter: Filter = .all

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28, pinnedViews: [.sectionHeaders]) {
                Section {
                    switch filter {
                    case .videos:
                        VideosContent()
                    case .all, .music:
                        content
                    }
                } header: {
                    header
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
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            AvatarButton()
            ForEach(Filter.allCases) { f in
                Chip(title: f.rawValue, selected: filter == f) { withAnimation(Theme.Motion.quick) { filter = f } }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.vertical, Theme.Spacing.s)
        .background(Theme.Palette.background)
    }

    @ViewBuilder private var content: some View {
        if let feed = model.feed {
            if feed.isCatalogEmpty {
                EmptyStateView(symbol: "music.note.house", title: "Nothing here yet", message: "New music and videos will appear here automatically as soon as they are added.")
            } else {
                let sections = feed.sections.filter { filter == .all || !["music_videos", "continue_watching"].contains($0.kind) }
                ShortcutGrid(items: shortcuts(from: feed))
                ForEach(sections) { section in
                    HomeSectionView(section: section, titleOverride: section.kind == "recently_played" ? "Jump back in" : nil)
                }
            }
        } else if let error = model.error {
            ErrorStateView(error: error) { Task { await model.load(api: app.api) } }
        } else {
            homeSkeleton
        }
    }

    /// Up to 8 quick-access tiles: Liked Songs, recent albums/playlists and your mixes.
    private func shortcuts(from feed: HomeFeed) -> [HomeItem] {
        var out: [HomeItem] = []
        var seen = Set<String>()
        for kind in ["recently_played", "made_for_you", "featured_playlists", "recently_added"] {
            for item in feed.sections.first(where: { $0.kind == kind })?.items ?? [] {
                switch item {
                case .album, .playlist, .mix, .artist:
                    if seen.insert(item.id).inserted { out.append(item) }
                default: break
                }
                if out.count >= 7 { break }
            }
        }
        return Array(out.prefix(7))
    }

    private var homeSkeleton: some View {
        VStack(alignment: .leading, spacing: 28) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(0..<8, id: \.self) { _ in Skeleton(height: 56, radius: 4) }
            }
            .padding(.horizontal, Theme.Spacing.screen)
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Skeleton(width: 180, height: 22).padding(.horizontal, Theme.Spacing.screen)
                    HStack(spacing: Theme.Spacing.l) {
                        ForEach(0..<3, id: \.self) { _ in Skeleton(width: 150, height: 150, radius: 4) }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                }
            }
        }
    }
}

/// Two-column grid of compact tiles (artwork on the left, bold title).
struct ShortcutGrid: View {
    let items: [HomeItem]
    @Environment(LibraryStore.self) private var library

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
            NavigationLink(value: Route.likedSongs) {
                ShortcutTile(title: "Liked Songs") {
                    Theme.Gradients.likedSongs.overlay(Image(systemName: "heart.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
                }
            }
            .buttonStyle(PressScaleStyle())
            ForEach(items) { item in
                if let r = route(for: item) {
                    NavigationLink(value: r) {
                        ShortcutTile(title: title(item)) { tileArt(item) }
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
    }

    private func title(_ item: HomeItem) -> String {
        switch item {
        case .album(let a): a.title
        case .playlist(let p): p.title
        case .mix(let m): m.title
        case .artist(let a): a.name
        default: ""
        }
    }

    @ViewBuilder private func tileArt(_ item: HomeItem) -> some View {
        switch item {
        case .album(let a): ArtworkView(url: a.artworkUrl, size: 56, cornerRadius: 0)
        case .playlist(let p):
            if p.artworkUrl == nil && p.mosaicUrls.count >= 4 { MosaicArtwork(urls: p.mosaicUrls, size: 56) } else { ArtworkView(url: p.artworkUrl ?? p.mosaicUrls.first, size: 56, cornerRadius: 0, placeholderSymbol: "music.note.list") }
        case .mix(let m): MixArtwork(mix: m, size: 56)
        case .artist(let a): ArtworkView(url: a.artworkUrl, size: 56, cornerRadius: 0, placeholderSymbol: "music.mic")
        default: Color.clear
        }
    }
}

struct ShortcutTile<Art: View>: View {
    let title: String
    @ViewBuilder let art: () -> Art
    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            art().frame(width: 56, height: 56).clipped()
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
        }
        .frame(height: 56)
        .background(Theme.Palette.tile)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct HomeSectionView: View {
    let section: HomeSection
    var titleOverride: String?
    private var title: String { titleOverride ?? section.title }
    @Environment(AudioPlayer.self) private var player

    private var tracks: [Track] {
        section.items.compactMap { if case .track(let t) = $0 { return t }; return nil }
    }

    var body: some View {
        switch section.layout {
        case "list":
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader(title: title, subtitle: titleOverride == nil ? section.subtitle : nil)
                ForEach(Array(tracks.prefix(5).enumerated()), id: \.element.id) { i, t in
                    TrackRow(track: t, subtitle: t.resumePositionMs.map { "\(t.artist.name) • \(Format.time(TimeInterval($0) / 1000)) left" }) {
                        player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "radio", title: section.title))
                        if let resume = t.resumePositionMs { Task { try? await Task.sleep(for: .milliseconds(600)); player.seek(to: TimeInterval(resume) / 1000) } }
                    }
                }
            }
        case "chips":
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.m) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { i, item in
                            if let r = route(for: item), case let name = itemName(item) {
                                NavigationLink(value: r) { CategoryTile(title: name, index: i, artwork: itemArt(item), width: 160, height: 96) }.buttonStyle(PressScaleStyle())
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                }
            }
        default:
            Shelf(title: title, subtitle: titleOverride == nil ? section.subtitle : nil, items: section.items) { item in
                HomeItemCard(item: item, siblings: tracks, sectionTitle: section.title)
            }
        }
    }

    private func itemName(_ item: HomeItem) -> String {
        switch item {
        case .genre(let g), .mood(let g): g.name.capitalized
        default: ""
        }
    }

    private func itemArt(_ item: HomeItem) -> URL? {
        switch item {
        case .genre(let g), .mood(let g): g.artworkUrl
        default: nil
        }
    }
}

/// Coloured category tile with tilted artwork in the corner (Browse / genres).
struct CategoryTile: View {
    let title: String
    let index: Int
    var artwork: URL?
    var width: CGFloat? = nil
    var height: CGFloat = 100

    static let colors: [UInt32] = [0xDC148C, 0x006450, 0x8400E7, 0x1E3264, 0xE8115B, 0x148A08, 0xBC5900, 0x503750, 0x477D95, 0xE1118C, 0x0D73EC, 0x27856A, 0x8D67AB, 0xBA5D07, 0x777777, 0xAF2896]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: Self.colors[index % Self.colors.count])
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let artwork {
                ArtworkView(url: artwork, size: height * 0.62, cornerRadius: 4)
                    .rotationEffect(.degrees(25))
                    .shadow(color: .black.opacity(0.35), radius: 6)
                    .offset(x: 18, y: 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

struct HomeItemCard: View {
    let item: HomeItem
    let siblings: [Track]
    let sectionTitle: String
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        switch item {
        case .track(let t):
            Button {
                let i = siblings.firstIndex(of: t) ?? 0
                player.play(tracks: siblings, startAt: i, context: PlaybackContext(type: "radio", title: sectionTitle))
            } label: {
                MediaCard(title: t.title, subtitle: "Song • \(t.artist.name)", artwork: t.artworkUrl)
            }
            .buttonStyle(PressScaleStyle())
            .contextMenu { TrackMenuItems(track: t) }
        case .album(let a):
            NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a) }.buttonStyle(PressScaleStyle())
        case .artist(let a):
            NavigationLink(value: Route.artist(a.id)) { ArtistCard(artist: a) }.buttonStyle(PressScaleStyle())
        case .playlist(let p):
            NavigationLink(value: Route.playlist(p.id)) { PlaylistCard(playlist: p) }.buttonStyle(PressScaleStyle())
        case .video(let v):
            NavigationLink(value: Route.video(v.id)) { VideoCard(video: v) }.buttonStyle(PressScaleStyle())
        case .mix(let m):
            NavigationLink(value: Route.mix(m.id, m.title)) { MixCard(mix: m) }.buttonStyle(PressScaleStyle())
        case .genre(let g), .mood(let g):
            if let r = route(for: item) { NavigationLink(value: r) { CategoryTile(title: g.name.capitalized, index: abs(g.name.hashValue) % 16, artwork: g.artworkUrl, width: 150, height: 150) }.buttonStyle(PressScaleStyle()) }
        case .unknown:
            EmptyView()
        }
    }
}
