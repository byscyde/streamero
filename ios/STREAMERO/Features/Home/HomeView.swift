import StreameroCore
import SwiftUI

@MainActor
@Observable
final class HomeModel {
    var feed: HomeFeed?
    var error: Error?
    var loading = false

    func load(api: APIClient?) async {
        guard let api else { return }
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
    @Environment(AudioPlayer.self) private var player
    @State private var model = HomeModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                header
                if let feed = model.feed {
                    if feed.isCatalogEmpty {
                        EmptyStateView(symbol: "waveform.badge.plus", title: "Your library is ready",
                                       message: "Nothing has been added to this STREAMERO server yet. An administrator can upload music and videos from the admin dashboard.")
                    } else if feed.sections.isEmpty {
                        EmptyStateView(symbol: "sparkles", title: "Start listening", message: "Search for an artist or song. Your mixes and recommendations appear here as you listen.",
                                       actionTitle: "Search") { app.selectedTab = .search }
                    }
                    ForEach(feed.sections) { section in
                        HomeSectionView(section: section)
                    }
                } else if let error = model.error {
                    ErrorStateView(error: error) { Task { await model.load(api: app.api) } }
                } else {
                    homeSkeleton
                }
            }
            .padding(.vertical, Theme.Spacing.l)
        }
        .refreshable { await model.load(api: app.api) }
        .streameroScreen()
        .toolbar(.hidden, for: .navigationBar)
        .task { if model.feed == nil { await model.load(api: app.api) } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.feed?.greeting ?? "Welcome").font(Theme.Typography.display).lineLimit(2).minimumScaleFactor(0.7)
                Text("STREAMERO").font(Theme.Typography.micro).tracking(2).foregroundStyle(Theme.Gradients.brandHorizontal)
            }
            Spacer()
            NavigationLink(value: Route.settings) {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(Theme.Palette.textSecondary).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Theme.Spacing.screen)
    }

    private var homeSkeleton: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Skeleton(width: 180, height: 20).padding(.horizontal, Theme.Spacing.screen)
                    HStack(spacing: Theme.Spacing.l) {
                        ForEach(0..<3, id: \.self) { _ in Skeleton(width: Theme.Size.card, height: Theme.Size.card, radius: Theme.Radius.artwork) }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                }
            }
        }
    }
}

struct HomeSectionView: View {
    let section: HomeSection
    @Environment(AudioPlayer.self) private var player

    private var tracks: [Track] {
        section.items.compactMap { if case .track(let t) = $0 { return t }; return nil }
    }

    var body: some View {
        switch section.layout {
        case "list":
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader(title: section.title, subtitle: section.subtitle)
                ForEach(Array(tracks.prefix(6).enumerated()), id: \.element.id) { i, t in
                    TrackRow(track: t, subtitle: t.resumePositionMs.map { "Resume at \(Format.time(TimeInterval($0) / 1000))" }) {
                        player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "radio", title: section.title))
                        if let resume = t.resumePositionMs { Task { try? await Task.sleep(for: .milliseconds(600)); player.seek(to: TimeInterval(resume) / 1000) } }
                    }
                }
            }
        case "chips":
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeader(title: section.title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(64)), GridItem(.fixed(64))], spacing: Theme.Spacing.m) {
                        ForEach(section.items) { item in
                            HomeItemCard(item: item, siblings: [], sectionTitle: section.title)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                }
            }
        default:
            Shelf(title: section.title, subtitle: section.subtitle, items: section.items) { item in
                HomeItemCard(item: item, siblings: tracks, sectionTitle: section.title)
            }
        }
    }
}

struct GenreTile: View {
    let tag: TagItem
    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ArtworkView(url: tag.artworkUrl, size: 48, cornerRadius: Theme.Radius.s, placeholderSymbol: "music.quarternote.3")
            Text(tag.name.capitalized).font(Theme.Typography.callout.weight(.bold)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 200, height: 64)
        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
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
                MediaCard(title: t.title, subtitle: t.artist.name, artwork: t.artworkUrl)
            }
            .buttonStyle(.plain)
            .contextMenu { TrackMenuItems(track: t) }
        case .album(let a):
            NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a) }.buttonStyle(.plain)
        case .artist(let a):
            NavigationLink(value: Route.artist(a.id)) { ArtistCard(artist: a) }.buttonStyle(.plain)
        case .playlist(let p):
            NavigationLink(value: Route.playlist(p.id)) { PlaylistCard(playlist: p) }.buttonStyle(.plain)
        case .video(let v):
            NavigationLink(value: Route.video(v.id)) { VideoCard(video: v) }.buttonStyle(.plain)
        case .mix(let m):
            NavigationLink(value: Route.mix(m.id, m.title)) { MixCard(mix: m) }.buttonStyle(.plain)
        case .genre(let g), .mood(let g):
            if let r = route(for: item) { NavigationLink(value: r) { GenreTile(tag: g) }.buttonStyle(.plain) }
        case .unknown:
            EmptyView()
        }
    }
}
