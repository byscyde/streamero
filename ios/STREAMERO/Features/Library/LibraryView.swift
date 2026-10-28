import StreameroKit
import SwiftUI

struct LibraryView: View {
    enum Part: String, CaseIterable, Identifiable { case movies = "Movies", series = "Series", music = "Music"; var id: String { rawValue } }
    @State private var section: Part = .movies

    var body: some View {
        VStack(spacing: 0) {
            Picker("Library", selection: $section) {
                ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)
            switch section {
            case .movies: MoviesListView()
            case .series: SeriesListView()
            case .music: ArtistsListView()
            }
        }
        .background(Theme.background)
        .navigationTitle("Library")
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", missing = "Missing", downloaded = "Downloaded", unmonitored = "Unmonitored"
    var id: String { rawValue }
}

// MARK: - Movies

struct MoviesListView: View {
    var body: some View {
        InstanceScope(kind: .radarr) { MoviesList(instance: $0) }
    }
}

struct MoviesList: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var movies: [Movie] = []
    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var error: String?
    @State private var loading = false

    private var visible: [Movie] {
        movies.filter(matches).sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
    }

    private func matches(_ m: Movie) -> Bool {
        if !query.isEmpty && !m.title.localizedCaseInsensitiveContains(query) { return false }
        switch filter {
        case .all: return true
        case .missing: return m.monitored == true && m.hasFile != true
        case .downloaded: return m.hasFile == true
        case .unmonitored: return m.monitored != true
        }
    }

    private func subtitle(_ m: Movie) -> String {
        var parts: [String] = []
        if let year = m.year { parts.append(String(year)) }
        if let quality = m.movieFile?.quality?.name { parts.append(quality) }
        if let size = m.sizeOnDisk, size > 0 { parts.append(Format.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        List {
            if let error, movies.isEmpty { ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear) }
            ForEach(visible) { movie in
                NavigationLink { MovieDetailView(instance: instance, movieId: movie.id, onChange: { Task { await load() } }) } label: {
                    MediaRow(title: movie.title, subtitle: subtitle(movie), poster: movie.images?.poster, status: movieStatus(movie))
                }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && movies.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: "Filter movies")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { FilterMenu(filter: $filter) }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AddMediaView(instance: instance) } label: { Image(systemName: "plus") }.accessibilityLabel("Add movie")
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { movies = try await app.radarr(instance).movies(); error = nil } catch { self.error = AppState.describe(error) }
    }
}

func movieStatus(_ movie: Movie) -> (String, Color) {
    if movie.hasFile == true { return ("Downloaded", Theme.ok) }
    if movie.monitored != true { return ("Unmonitored", Theme.textSecondary) }
    if movie.isAvailable == true { return ("Missing", Theme.error) }
    return ((movie.status ?? "announced").capitalized, Theme.warning)
}

struct MediaRow: View {
    var title: String
    var subtitle: String
    var poster: URL?
    var status: (String, Color)?
    var progress: Double?

    var body: some View {
        HStack(spacing: 12) {
            Poster(url: poster, width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                if let progress { ProgressBar(value: progress, color: progress >= 1 ? Theme.ok : Theme.accent).frame(maxWidth: 160) }
            }
            Spacer()
            if let status { Pill(text: status.0, color: status.1) }
        }
    }
}

struct FilterMenu: View {
    @Binding var filter: LibraryFilter
    var body: some View {
        Menu {
            Picker("Show", selection: $filter) { ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) } }
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter")
    }
}

struct MovieDetailView: View {
    var instance: ServiceInstance
    var movieId: Int
    var onChange: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var movie: Movie?
    @State private var confirmDelete = false
    @State private var sheet: DetailSheet?

    var body: some View {
        List {
            if let movie {
                Section { DetailHeader(title: movie.title, subtitle: [movie.year.map(String.init), movie.runtime.map { "\($0) min" }, movie.studio].compactMap { $0 }.joined(separator: " · "), poster: movie.images?.poster, overview: movie.overview, status: movieStatus(movie)) }
                Section("File") {
                    if let file = movie.movieFile {
                        LabeledContent("Quality", value: file.quality?.name ?? "—")
                        LabeledContent("Size", value: Format.bytes(file.size))
                        if let path = file.relativePath { Text(path).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary) }
                    } else {
                        Text("No file yet").foregroundStyle(Theme.textSecondary)
                    }
                    if let path = movie.path { LabeledContent("Folder", value: path).font(.caption) }
                }
                if let genres = movie.genres, !genres.isEmpty { Section("Genres") { Text(genres.joined(separator: ", ")) } }
                Section {
                    Button { act("Search started") { try await $0.search(movieIds: [movieId]) } } label: { Label("Search now", systemImage: "magnifyingglass") }
                    Button { sheet = .releases } label: { Label("Interactive search", systemImage: "person.fill.viewfinder") }
                    Button { sheet = .edit } label: { Label("Edit profile, tags, availability", systemImage: "slider.horizontal.3") }
                    Button { act("Refreshing") { try await $0.refresh(movieIds: [movieId]) } } label: { Label("Refresh & rescan", systemImage: "arrow.clockwise") }
                    Button {
                        let monitored = !(movie.monitored ?? false)
                        act(monitored ? "Monitored" : "Unmonitored") { try await $0.setMonitored(movieId: movieId, monitored) }
                    } label: { Label(movie.monitored == true ? "Unmonitor" : "Monitor", systemImage: movie.monitored == true ? "bookmark.slash" : "bookmark") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete movie", systemImage: "trash") }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(movie?.title ?? "Movie")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { kind in
            NavigationStack {
                switch kind {
                case .releases: ReleasesSheet(instance: instance, target: .movie(movieId), title: movie?.title ?? "Releases")
                case .edit: ItemEditView(instance: instance, path: "movie/\(movieId)") { Task { await load() }; onChange() }
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Delete \(movie?.title ?? "movie")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from Radarr", role: .destructive) { delete(files: false) }
            Button("Delete and remove files", role: .destructive) { delete(files: true) }
        }
    }

    private func load() async { movie = try? await app.radarr(instance).movie(movieId) }

    private func act(_ message: String, _ action: @escaping (RadarrClient) async throws -> Void) {
        app.perform(message) {
            try await action(try app.radarr(instance))
            await load()
            onChange()
        }
    }

    private func delete(files: Bool) {
        app.perform("Deleted") {
            try await app.radarr(instance).delete(movieId: movieId, deleteFiles: files)
            onChange()
            dismiss()
        }
    }
}

struct DetailHeader: View {
    var title: String
    var subtitle: String
    var poster: URL?
    var overview: String?
    var status: (String, Color)?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Poster(url: poster, width: 100)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(.title3, design: .monospaced).weight(.bold))
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                    if let status { Pill(text: status.0, color: status.1) }
                }
            }
            if let overview, !overview.isEmpty { Text(overview).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(8) }
        }
    }
}

// MARK: - Series

struct SeriesListView: View {
    var body: some View {
        InstanceScope(kind: .sonarr) { SeriesList(instance: $0) }
    }
}

struct SeriesList: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var series: [Series] = []
    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var error: String?
    @State private var loading = false

    private var visible: [Series] {
        series.filter(matches).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func matches(_ s: Series) -> Bool {
        if !query.isEmpty && !s.title.localizedCaseInsensitiveContains(query) { return false }
        switch filter {
        case .all: return true
        case .missing: return s.monitored == true && s.episodeProgress < 1
        case .downloaded: return s.episodeProgress >= 1
        case .unmonitored: return s.monitored != true
        }
    }

    private func subtitle(_ s: Series) -> String {
        var parts: [String] = []
        if let year = s.year { parts.append(String(year)) }
        if let network = s.network { parts.append(network) }
        if let stats = s.statistics { parts.append("\(stats.episodeFileCount ?? 0)/\(stats.episodeCount ?? 0) episodes") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        List {
            if let error, series.isEmpty { ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear) }
            ForEach(visible) { s in
                NavigationLink { SeriesDetailView(instance: instance, seriesId: s.id, onChange: { Task { await load() } }) } label: {
                    MediaRow(title: s.title, subtitle: subtitle(s), poster: s.images?.poster,
                             status: s.monitored == true ? nil : ("Unmonitored", Theme.textSecondary), progress: s.episodeProgress)
                }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && series.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: "Filter series")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { FilterMenu(filter: $filter) }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AddMediaView(instance: instance) } label: { Image(systemName: "plus") }.accessibilityLabel("Add series")
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { series = try await app.sonarr(instance).series(); error = nil } catch { self.error = AppState.describe(error) }
    }
}

struct SeriesDetailView: View {
    var instance: ServiceInstance
    var seriesId: Int
    var onChange: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var series: Series?
    @State private var episodes: [Episode] = []
    @State private var confirmDelete = false
    @State private var editing = false

    var body: some View {
        List {
            if let series {
                Section {
                    DetailHeader(title: series.title,
                                 subtitle: [series.year.map(String.init), series.network, series.status?.capitalized].compactMap { $0 }.joined(separator: " · "),
                                 poster: series.images?.poster, overview: series.overview,
                                 status: series.monitored == true ? nil : ("Unmonitored", Theme.textSecondary))
                    if let stats = series.statistics {
                        LabeledContent("Episodes", value: "\(stats.episodeFileCount ?? 0) of \(stats.episodeCount ?? 0)")
                        LabeledContent("Size", value: Format.bytes(stats.sizeOnDisk))
                    }
                    if let next = series.nextAiring, Format.isRealDate(next) { LabeledContent("Next episode", value: next.formatted(date: .abbreviated, time: .shortened)) }
                }
                Section("Seasons") {
                    ForEach((series.seasons ?? []).sorted { $0.seasonNumber > $1.seasonNumber }) { season in
                        NavigationLink {
                            SeasonView(instance: instance, seriesId: seriesId, season: season.seasonNumber, episodes: episodes.filter { $0.seasonNumber == season.seasonNumber })
                        } label: {
                            let stats = season.statistics
                            MediaRow(title: season.seasonNumber == 0 ? "Specials" : "Season \(season.seasonNumber)",
                                     subtitle: "\(stats?.episodeFileCount ?? 0)/\(stats?.episodeCount ?? 0) episodes · \(Format.bytes(stats?.sizeOnDisk))",
                                     poster: nil, status: season.monitored == true ? nil : ("Unmonitored", Theme.textSecondary),
                                     progress: (stats?.percentOfEpisodes ?? 0) / 100)
                        }
                    }
                }
                Section {
                    Button { act("Search started") { try await $0.searchSeries(seriesId) } } label: { Label("Search all missing", systemImage: "magnifyingglass") }
                    Button { editing = true } label: { Label("Edit profile, type, seasons, tags", systemImage: "slider.horizontal.3") }
                    Button { act("Refreshing") { try await $0.refreshSeries(seriesId) } } label: { Label("Refresh & rescan", systemImage: "arrow.clockwise") }
                    Button {
                        let monitored = !(series.monitored ?? false)
                        act(monitored ? "Monitored" : "Unmonitored") { try await $0.setMonitored(seriesId: seriesId, monitored) }
                    } label: { Label(series.monitored == true ? "Unmonitor" : "Monitor", systemImage: series.monitored == true ? "bookmark.slash" : "bookmark") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete series", systemImage: "trash") }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(series?.title ?? "Series")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            NavigationStack { ItemEditView(instance: instance, path: "series/\(seriesId)") { Task { await load() }; onChange() } }
        }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Delete \(series?.title ?? "series")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from Sonarr", role: .destructive) { delete(files: false) }
            Button("Delete and remove files", role: .destructive) { delete(files: true) }
        }
    }

    private func load() async {
        guard let client = try? app.sonarr(instance) else { return }
        series = try? await client.series(seriesId)
        episodes = (try? await client.episodes(seriesId: seriesId)) ?? []
    }

    private func act(_ message: String, _ action: @escaping (SonarrClient) async throws -> Void) {
        app.perform(message) {
            try await action(try app.sonarr(instance))
            await load()
            onChange()
        }
    }

    private func delete(files: Bool) {
        app.perform("Deleted") {
            try await app.sonarr(instance).delete(seriesId: seriesId, deleteFiles: files)
            onChange()
            dismiss()
        }
    }
}

struct SeasonView: View {
    var instance: ServiceInstance
    var seriesId: Int
    var season: Int
    @State var episodes: [Episode]
    @Environment(AppState.self) private var app
    @State private var search: ReleaseQuery?

    var body: some View {
        List {
            Section {
                Button { app.perform("Season search started") { try await app.sonarr(instance).searchSeason(seriesId: seriesId, season: season) } } label: {
                    Label("Search whole season", systemImage: "magnifyingglass")
                }
                Button { search = ReleaseQuery(target: .season(seriesId: seriesId, season: season), title: season == 0 ? "Specials" : "Season \(season)") } label: {
                    Label("Interactive search (season packs)", systemImage: "person.fill.viewfinder")
                }
            }
            ForEach(episodes.sorted { $0.episodeNumber > $1.episodeNumber }) { episode in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(episode.code).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                        Text(episode.title ?? "TBA").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Image(systemName: episode.hasFile == true ? "checkmark.circle.fill" : (episode.monitored == true ? "circle" : "bookmark.slash"))
                            .foregroundStyle(episode.hasFile == true ? Theme.ok : Theme.textSecondary)
                    }
                    if let date = episode.airDateUtc, Format.isRealDate(date) {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                .swipeActions {
                    Button { app.perform("Searching \(episode.code)") { try await app.sonarr(instance).searchEpisodes([episode.id]) } } label: { Label("Search", systemImage: "magnifyingglass") }
                        .tint(Theme.accent)
                    Button { search = ReleaseQuery(target: .episode(episode.id), title: episode.code) } label: { Label("Releases", systemImage: "person.fill.viewfinder") }
                        .tint(.indigo)
                    Button {
                        let monitored = !(episode.monitored ?? false)
                        app.perform(monitored ? "Monitored" : "Unmonitored") {
                            try await app.sonarr(instance).setEpisodesMonitored([episode.id], monitored)
                            if let index = episodes.firstIndex(of: episode) { episodes[index].monitored = monitored }
                        }
                    } label: { Label(episode.monitored == true ? "Unmonitor" : "Monitor", systemImage: "bookmark") }
                }
            }
        }
        .navigationTitle(season == 0 ? "Specials" : "Season \(season)")
        .sheet(item: $search) { query in
            NavigationStack { ReleasesSheet(instance: instance, target: query.target, title: query.title) }
        }
    }
}

// MARK: - Music

struct ArtistsListView: View {
    var body: some View {
        InstanceScope(kind: .lidarr) { ArtistsList(instance: $0) }
    }
}

struct ArtistsList: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var artists: [Artist] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if let error, artists.isEmpty { ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear) }
            ForEach(artists.filter { query.isEmpty || $0.artistName.localizedCaseInsensitiveContains(query) }.sorted { $0.artistName < $1.artistName }) { artist in
                NavigationLink { ArtistDetailView(instance: instance, artist: artist, onChange: { Task { await load() } }) } label: {
                    MediaRow(title: artist.artistName,
                             subtitle: artist.statistics.map { "\($0.albumCount ?? 0) albums · \($0.trackFileCount ?? 0)/\($0.trackCount ?? 0) tracks" } ?? "",
                             poster: artist.images?.poster, status: artist.monitored == true ? nil : ("Unmonitored", Theme.textSecondary),
                             progress: (artist.statistics?.percentOfTracks ?? 0) / 100)
                }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && artists.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: "Filter artists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AddMediaView(instance: instance) } label: { Image(systemName: "plus") }.accessibilityLabel("Add artist")
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { artists = try await app.lidarr(instance).artists(); error = nil } catch { self.error = AppState.describe(error) }
    }
}

struct ArtistDetailView: View {
    var instance: ServiceInstance
    var artist: Artist
    var onChange: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album] = []
    @State private var confirmDelete = false
    @State private var search: ReleaseQuery?
    @State private var editing = false

    var body: some View {
        List {
            Section { DetailHeader(title: artist.artistName, subtitle: (artist.genres ?? []).prefix(3).joined(separator: ", "), poster: artist.images?.poster, overview: artist.overview, status: nil) }
            Section("Albums") {
                ForEach(albums.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }) { album in
                    MediaRow(title: album.title,
                             subtitle: [album.releaseDate.flatMap { Format.isRealDate($0) ? $0.formatted(.dateTime.year()) : nil }, album.albumType].compactMap { $0 }.joined(separator: " · "),
                             poster: album.images?.poster, status: nil, progress: (album.statistics?.percentOfTracks ?? 0) / 100)
                        .swipeActions {
                            Button { app.perform("Searching \(album.title)") { try await app.lidarr(instance).searchAlbums([album.id]) } } label: { Label("Search", systemImage: "magnifyingglass") }
                                .tint(Theme.accent)
                            Button { search = ReleaseQuery(target: .album(album.id), title: album.title) } label: { Label("Releases", systemImage: "person.fill.viewfinder") }
                                .tint(.indigo)
                        }
                }
            }
            Section {
                Button { app.perform("Search started") { try await app.lidarr(instance).searchArtist(artist.id) } } label: { Label("Search all missing albums", systemImage: "magnifyingglass") }
                Button { editing = true } label: { Label("Edit profiles and tags", systemImage: "slider.horizontal.3") }
                Button {
                    let monitored = !(artist.monitored ?? false)
                    app.perform(monitored ? "Monitored" : "Unmonitored") { try await app.lidarr(instance).setMonitored(artistId: artist.id, monitored); onChange() }
                } label: { Label(artist.monitored == true ? "Unmonitor" : "Monitor", systemImage: "bookmark") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete artist", systemImage: "trash") }
            }
        }
        .navigationTitle(artist.artistName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $search) { query in
            NavigationStack { ReleasesSheet(instance: instance, target: query.target, title: query.title) }
        }
        .sheet(isPresented: $editing) {
            NavigationStack { ItemEditView(instance: instance, path: "artist/\(artist.id)", onSave: onChange) }
        }
        .task { albums = (try? await app.lidarr(instance).albums(artistId: artist.id)) ?? [] }
        .confirmationDialog("Delete \(artist.artistName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from Lidarr", role: .destructive) { delete(files: false) }
            Button("Delete and remove files", role: .destructive) { delete(files: true) }
        }
    }

    private func delete(files: Bool) {
        app.perform("Deleted") {
            try await app.lidarr(instance).delete(artistId: artist.id, deleteFiles: files)
            onChange()
            dismiss()
        }
    }
}
