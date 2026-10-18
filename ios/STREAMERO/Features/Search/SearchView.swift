import StreameroCore
import SwiftUI

@MainActor
@Observable
final class SearchModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, tracks, artists, albums, playlists, videos
        var id: String { rawValue }
        var title: String { self == .all ? "All" : rawValue.capitalized }
    }

    var query = ""
    var filter: Filter = .all
    private(set) var results: SearchResults?
    private(set) var suggestions: [SearchSuggestion] = []
    private(set) var recent: [String] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var error: Error?
    private(set) var genres: [GenreInfo] = []

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored var api: APIClient?

    /// Debounced: each keystroke cancels the previous in-flight request so stale results never win.
    func queryChanged() {
        searchTask?.cancel()
        suggestTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; suggestions = []; error = nil; loading = false; return }
        loading = true
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let api else { return }
            let s = (try? await api.suggestions(q)) ?? []
            if !Task.isCancelled, q == query.trimmingCharacters(in: .whitespaces) { suggestions = s }
        }
        searchTask = Task { await run(q, delay: .milliseconds(300)) }
    }

    func filterChanged() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        searchTask = Task { await run(q, delay: .zero) }
    }

    private func run(_ q: String, delay: Duration) async {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let api else { return }
        do {
            let types = filter == .all ? [] : [filter.rawValue]
            let r = try await api.search(q, types: types, limit: filter == .all ? 8 : 30)
            guard !Task.isCancelled else { return }
            results = r.results
            error = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error
        }
        loading = false
    }

    /// Pagination for a single-type search.
    func loadMore() async {
        guard filter != .all, !loadingMore, let api, let r = results else { return }
        let next: Int?
        switch filter {
        case .tracks: next = r.tracks?.nextOffset
        case .artists: next = r.artists?.nextOffset
        case .albums: next = r.albums?.nextOffset
        case .playlists: next = r.playlists?.nextOffset
        case .videos: next = r.videos?.nextOffset
        case .all: next = nil
        }
        guard let offset = next else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await api.search(query, types: [filter.rawValue], limit: 30, offset: offset) else { return }
        var merged = r
        func merge<T>(_ a: Page<T>?, _ b: Page<T>?) -> Page<T>? {
            guard var a, let b else { return a ?? b }
            a.items += b.items
            a.nextOffset = b.nextOffset
            return a
        }
        merged.tracks = merge(r.tracks, page.results.tracks)
        merged.artists = merge(r.artists, page.results.artists)
        merged.albums = merge(r.albums, page.results.albums)
        merged.playlists = merge(r.playlists, page.results.playlists)
        merged.videos = merge(r.videos, page.results.videos)
        results = merged
    }

    func commit() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        recent.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recent.insert(q, at: 0)
        recent = Array(recent.prefix(15))
        Task { try? await api?.addRecentSearch(q) }
    }

    func loadInitial() async {
        guard let api else { return }
        async let r = try? api.recentSearches()
        async let g = try? api.genres()
        if let list = await r { recent = list.map(\.query) }
        if let g = await g { genres = g.genres + g.moods.map { var m = $0; m.kind = "mood"; return m } }
    }

    func clearRecent() {
        recent = []
        Task { try? await api?.clearRecentSearches() }
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(AudioPlayer.self) private var player
    @State private var model = SearchModel()
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.l, pinnedViews: [.sectionHeaders]) {
                Section {
                    content
                } header: {
                    VStack(spacing: Theme.Spacing.s) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.textTertiary)
                            TextField("Artists, songs, albums, videos", text: $model.query)
                                .focused($focused)
                                .submitLabel(.search)
                                .autocorrectionDisabled()
                                .onSubmit { model.commit() }
                                .accessibilityIdentifier("searchField")
                            if !model.query.isEmpty {
                                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.textTertiary) }
                                    .accessibilityLabel("Clear search")
                            }
                        }
                        .padding(Theme.Spacing.m)
                        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                        if !model.query.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Theme.Spacing.s) {
                                    ForEach(SearchModel.Filter.allCases) { f in
                                        Chip(title: f.title, selected: model.filter == f) { model.filter = f; model.filterChanged() }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                    .padding(.vertical, Theme.Spacing.s)
                    .background(Theme.Palette.background)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .streameroScreen()
        .navigationTitle("Search")
        .onChange(of: model.query) { model.queryChanged() }
        .task {
            model.api = app.api
            await model.loadInitial()
        }
    }

    @ViewBuilder private var content: some View {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            browse
        } else if let error = model.error, model.results == nil {
            ErrorStateView(error: error) { model.filterChanged() }
        } else if model.loading && model.results == nil {
            suggestionList
            SkeletonRows(count: 5)
        } else if let r = model.results {
            if r.isEmpty && !model.loading {
                EmptyStateView(symbol: "magnifyingglass", title: "No results for “\(model.query)”", message: "Check the spelling or try fewer words.")
            } else {
                results(r)
            }
        }
    }

    private var suggestionList: some View {
        ForEach(model.suggestions) { s in
            Button {
                model.query = s.text
                model.commit()
            } label: {
                Label(s.text, systemImage: s.type == "artist" ? "music.mic" : s.type == "album" ? "square.stack" : s.type == "video" ? "play.rectangle" : "music.note")
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Spacing.screen)
            }
        }
    }

    @ViewBuilder private var browse: some View {
        if !model.recent.isEmpty {
            SectionHeader(title: "Recent searches", action: ("Clear", { model.clearRecent() }))
            ForEach(model.recent, id: \.self) { q in
                Button { model.query = q } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.Palette.textTertiary)
                        Text(q).foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                }
            }
        }
        if !model.genres.isEmpty {
            SectionHeader(title: "Browse")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.m), GridItem(.flexible())], spacing: Theme.Spacing.m) {
                ForEach(Array(model.genres.prefix(24).enumerated()), id: \.element.id) { i, g in
                    NavigationLink(value: Route.tag(kind: g.kind ?? "genre", name: g.name)) {
                        Text(g.name.capitalized)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                            .padding(Theme.Spacing.m)
                            .background(tileGradient(i), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.screen)
        }
        NavigationLink(value: Route.youtube) {
            Label("Discover on YouTube", systemImage: "play.tv").font(Theme.Typography.callout.weight(.semibold))
        }
        .padding(.horizontal, Theme.Spacing.screen)
    }

    private func tileGradient(_ i: Int) -> LinearGradient {
        let palettes: [[Color]] = [[Theme.Palette.violet, Theme.Palette.blue], [Theme.Palette.blue, Theme.Palette.turquoise], [Theme.Palette.turquoise, Theme.Palette.violet], [Color(hex: 0x6D28D9), Color(hex: 0x1E3A8A)]]
        return LinearGradient(colors: palettes[i % palettes.count], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder private func results(_ r: SearchResults) -> some View {
        let tracks = r.tracks?.items ?? []
        if let artists = r.artists?.items, !artists.isEmpty, model.filter == .all || model.filter == .artists {
            if model.filter == .all {
                Shelf(title: "Artists", items: artists) { a in NavigationLink(value: Route.artist(a.id)) { ArtistCard(artist: a, size: 100) }.buttonStyle(.plain) }
            } else {
                ForEach(artists) { a in
                    NavigationLink(value: Route.artist(a.id)) {
                        HStack(spacing: Theme.Spacing.m) {
                            ArtworkView(url: a.artworkUrl, size: 52, placeholderSymbol: "music.mic", circular: true)
                            Text(a.name).font(Theme.Typography.body.weight(.medium)).foregroundStyle(Theme.Palette.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Spacing.screen)
                    }
                    .onAppear { if a.id == artists.last?.id { Task { await model.loadMore() } } }
                }
            }
        }
        if !tracks.isEmpty, model.filter == .all || model.filter == .tracks {
            if model.filter == .all { SectionHeader(title: "Songs") }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t) {
                    model.commit()
                    player.play(tracks: tracks, startAt: i, context: PlaybackContext(type: "search", title: model.query))
                }
                .onAppear { if t.id == tracks.last?.id { Task { await model.loadMore() } } }
            }
        }
        if let albums = r.albums?.items, !albums.isEmpty, model.filter == .all || model.filter == .albums {
            if model.filter == .all {
                Shelf(title: "Albums", items: albums) { a in NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a) }.buttonStyle(.plain) }
            } else {
                grid(albums) { a in NavigationLink(value: Route.album(a.id)) { AlbumCard(album: a, size: 160) }.buttonStyle(.plain) }
            }
        }
        if let playlists = r.playlists?.items, !playlists.isEmpty, model.filter == .all || model.filter == .playlists {
            Shelf(title: "Playlists", items: playlists) { p in NavigationLink(value: Route.playlist(p.id)) { PlaylistCard(playlist: p) }.buttonStyle(.plain) }
        }
        if let videos = r.videos?.items, !videos.isEmpty, model.filter == .all || model.filter == .videos {
            Shelf(title: "Videos", items: videos) { v in NavigationLink(value: Route.video(v.id)) { VideoCard(video: v) }.buttonStyle(.plain) }
        }
        if let genres = r.genres?.items, !genres.isEmpty, model.filter == .all {
            SectionHeader(title: "Genres & moods")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(genres) { g in
                        NavigationLink(value: Route.tag(kind: g.kind ?? "genre", name: g.name)) { Text(g.name.capitalized) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.horizontal, Theme.Spacing.screen)
            }
        }
        if model.loadingMore { ProgressView().frame(maxWidth: .infinity) }
    }

    private func grid<T: Identifiable, V: View>(_ items: [T], @ViewBuilder card: @escaping (T) -> V) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.l)], spacing: Theme.Spacing.l) {
            ForEach(items) { card($0) }
        }
        .padding(.horizontal, Theme.Spacing.screen)
    }
}
