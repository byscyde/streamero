import StreameroKit
import SwiftUI

struct SubtitlesView: View {
    var body: some View {
        InstanceScope(kind: .bazarr) { BazarrHome(instance: $0) }
            .navigationTitle("Subtitles")
    }
}

struct BazarrHome: View {
    enum Part: String, CaseIterable, Identifiable { case wanted = "Wanted", history = "History", providers = "Providers", tasks = "Tasks"; var id: String { rawValue } }
    var instance: ServiceInstance
    @State private var part: Part = .wanted

    var body: some View {
        VStack(spacing: 0) {
            Picker("Subtitles", selection: $part) { ForEach(Part.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)
            switch part {
            case .wanted: BazarrWantedView(instance: instance)
            case .history: BazarrHistoryView(instance: instance)
            case .providers: BazarrProvidersView(instance: instance)
            case .tasks: BazarrTasksView(instance: instance)
            }
        }
    }
}

struct BazarrWantedView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var episodes: [WantedEpisode] = []
    @State private var movies: [WantedMovie] = []
    @State private var totals = (episodes: 0, movies: 0)
    @State private var loading = false

    var body: some View {
        List {
            if episodes.isEmpty && movies.isEmpty && !loading { ContentUnavailableView("No missing subtitles", systemImage: "captions.bubble") }
            if !episodes.isEmpty {
                Section("Episodes (\(totals.episodes))") {
                    ForEach(episodes) { episode in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(episode.seriesTitle ?? "") \(episode.episodeNumber ?? "")").font(.subheadline.weight(.semibold))
                            if let title = episode.episodeTitle { Text(title).font(.caption).foregroundStyle(Theme.textSecondary) }
                            languageButtons(episode.missingSubtitles) { language in
                                try await app.bazarr(instance).downloadSubtitle(episode: episode, language: language)
                            }
                        }
                    }
                }
            }
            if !movies.isEmpty {
                Section("Movies (\(totals.movies))") {
                    ForEach(movies) { movie in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(movie.title ?? "Movie").font(.subheadline.weight(.semibold))
                            languageButtons(movie.missingSubtitles) { language in
                                try await app.bazarr(instance).downloadSubtitle(movie: movie, language: language)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if loading && episodes.isEmpty && movies.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
    }

    /// One button per missing language; tapping searches providers and downloads the best match.
    private func languageButtons(_ languages: [SubtitleLanguage], download: @escaping (SubtitleLanguage) async throws -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(languages, id: \.self) { language in
                    Button {
                        app.perform("Searching \(language.label) subtitles") {
                            try await download(language)
                            await load()
                        }
                    } label: { Label(language.label, systemImage: "arrow.down.circle") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = try? app.bazarr(instance) else { return }
        do {
            let e = try await client.wantedEpisodes()
            episodes = e.data
            totals.episodes = e.total ?? e.data.count
        } catch { app.show(AppState.describe(error), error: true) }
        if let m = try? await client.wantedMovies() {
            movies = m.data
            totals.movies = m.total ?? m.data.count
        }
    }
}

struct BazarrHistoryView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var entries: [SubtitleHistoryEntry] = []

    var body: some View {
        List(entries) { entry in
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let description = entry.description { Text(description).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(3) }
                Text([entry.language?.label, entry.provider, entry.timestamp].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .overlay { if entries.isEmpty { ContentUnavailableView("No subtitle history", systemImage: "clock") } }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = try? app.bazarr(instance) else { return }
        let episodes = (try? await client.episodeHistory()) ?? []
        let movies = (try? await client.movieHistory()) ?? []
        entries = (episodes + movies).sorted { ($0.timestamp ?? "") > ($1.timestamp ?? "") }
    }
}

struct BazarrProvidersView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var providers: [SubtitleProvider] = []

    var body: some View {
        List {
            Section {
                Button { app.perform("Providers reset") { try await app.bazarr(instance).resetProviders(); await load() } } label: {
                    Label("Reset throttled providers", systemImage: "arrow.counterclockwise")
                }
            }
            Section("Providers") {
                if providers.isEmpty { Text("All providers are working.").foregroundStyle(Theme.textSecondary) }
                ForEach(providers) { provider in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name).font(.subheadline.weight(.semibold))
                        Text([provider.status, provider.retry.map { "retry \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.warning)
                    }
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { providers = (try? await app.bazarr(instance).providers()) ?? [] }
}

struct BazarrTasksView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var tasks: [BazarrTask] = []

    var body: some View {
        List(tasks) { task in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).font(.subheadline.weight(.semibold))
                    Text([task.interval, task.nextRunIn.map { "next \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if task.jobRunning == true {
                    ProgressView()
                } else {
                    Button("Run") { app.perform("Started \(task.name)") { try await app.bazarr(instance).run(task: task.jobId); await load() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { tasks = (try? await app.bazarr(instance).tasks()) ?? [] }
}
