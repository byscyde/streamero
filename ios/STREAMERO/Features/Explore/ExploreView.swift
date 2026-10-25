import StreameroCore
import SwiftUI

@MainActor
@Observable
final class ExploreModel {
    var genres: [GenreInfo] = []
    var moods: [GenreInfo] = []
    var feed: HomeFeed?
    var videos: [Video] = []
    var loaded = false
    var error: Error?

    func load(api: APIClient?, includeVideos: Bool) async {
        guard let api else { return }
        async let g = try? api.genres()
        async let h = try? api.home()
        async let v: [Video] = includeVideos ? ((try? await api.videos(limit: 12))?.items ?? []) : []
        let (genres, feed, videos) = await (g, h, v)
        if let genres {
            self.genres = genres.genres
            self.moods = genres.moods.map { var m = $0; m.kind = "mood"; return m }
        }
        if let feed { self.feed = feed; JSONFileStore.save(feed, to: "home-cache") } else if self.feed == nil { self.feed = JSONFileStore.load(HomeFeed.self, from: "home-cache") }
        self.videos = videos
        error = (genres == nil && feed == nil) ? APIError.network("offline") : nil
        loaded = true
    }

    func section(_ id: String) -> HomeSection? {
        feed?.sections.first { HomeSectionOrdering.configId(forKind: $0.kind) == id && !$0.items.isEmpty }
    }
}

/// Explore: genres, top artists, new albums, recommended playlists, music videos and YouTube discovery.
struct ExploreView: View {
    @Environment(AppModel.self) private var app
    @Environment(SyncCenter.self) private var sync
    @Environment(AppearanceStore.self) private var appearance
    @State private var model = ExploreModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HStack(spacing: Theme.Spacing.m) {
                    AvatarButton()
                    Text("Explore").font(Theme.Typography.screenTitle)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.screen)
                .padding(.top, Theme.Spacing.s)

                if !model.genres.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        SectionHeader(title: "Genres", more: .genres)
                        GenreChipRow(names: model.genres.prefix(20).map { (name: $0.name, kind: "genre") })
                    }
                }
                if !model.moods.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        SectionHeader(title: "Moods", more: .genres)
                        GenreChipRow(names: model.moods.prefix(20).map { (name: $0.name, kind: "mood") })
                    }
                }
                ForEach(["top_artists", "new_albums", "recommended_playlists", "popular_singles"], id: \.self) { id in
                    if let section = model.section(id) { HomeSectionView(section: section) }
                }
                if appearance.features.videos && !model.videos.isEmpty {
                    Shelf(title: "Music videos", more: .videos, items: model.videos) { v in
                        NavigationLink(value: Route.video(v.id)) { VideoCard(video: v) }.buttonStyle(PressScaleStyle())
                    }
                }
                if appearance.features.youtube {
                    NavigationLink(value: Route.youtube) { youtubeCard }
                        .buttonStyle(PressScaleStyle())
                        .padding(.horizontal, Theme.Spacing.screen)
                }
                if model.loaded && model.genres.isEmpty && model.feed == nil, let error = model.error {
                    ErrorStateView(error: error) { Task { await reload() } }
                } else if !model.loaded {
                    SkeletonRows(count: 4)
                }
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
        .refreshable { await reload() }
        .streameroScreen()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: sync.catalogRevision) { await reload() }
    }

    private func reload() async { await model.load(api: app.api, includeVideos: appearance.features.videos) }

    private var youtubeCard: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.Gradients.brand, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("YouTube discovery").font(Theme.Typography.media(16)).foregroundStyle(Theme.Palette.textPrimary)
                Text("Search and watch official videos").font(.system(size: 14)).foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Spacing.m)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// All genres and moods as gradient tiles ("More" on genre sections).
struct GenresView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AsyncContent(load: { try await app.api!.genres() }) { (response: GenresResponse) in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    grid("Genres", response.genres, kind: "genre")
                    grid("Moods", response.moods, kind: "mood")
                }
                .padding(.vertical, Theme.Spacing.l)
            }
        }
        .streameroScreen()
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func grid(_ title: String, _ items: [GenreInfo], kind: String) -> some View {
        if !items.isEmpty {
            SectionHeader(title: title)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.m), GridItem(.flexible())], spacing: Theme.Spacing.m) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, g in
                    NavigationLink(value: Route.tag(kind: kind, name: g.name)) { CategoryTile(title: g.name.capitalized, index: i) }
                        .buttonStyle(PressScaleStyle())
                }
            }
            .padding(.horizontal, Theme.Spacing.screen)
        }
    }
}
