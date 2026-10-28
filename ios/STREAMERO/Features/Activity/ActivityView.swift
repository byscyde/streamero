import StreameroKit
import SwiftUI

struct ActivityView: View {
    enum Part: String, CaseIterable, Identifiable { case queue = "Queue", calendar = "Calendar", wanted = "Wanted", history = "History"; var id: String { rawValue } }
    @State private var part: Part = .queue

    var body: some View {
        VStack(spacing: 0) {
            Picker("Activity", selection: $part) { ForEach(Part.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)
            switch part {
            case .queue: QueueView()
            case .calendar: CalendarView()
            case .wanted: WantedView()
            case .history: HistoryView()
            }
        }
        .background(Theme.background)
        .navigationTitle("Activity")
    }
}

struct QueueView: View {
    @Environment(AppState.self) private var app
    @State private var items: [ActivityDownload] = []
    @State private var errors: [String] = []
    @State private var loading = false
    @State private var removing: ActivityDownload?

    var body: some View {
        List {
            ForEach(errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).font(.footnote) }
            if items.isEmpty && !loading {
                ContentUnavailableView("Nothing downloading", systemImage: "arrow.down.circle", description: Text("Sonarr, Radarr and Lidarr queues are empty."))
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: Theme.icon(item.kind)).foregroundStyle(Theme.accent)
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(item.timeLeft ?? Format.percent(item.progress)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                    if let subtitle = item.subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                    ProgressBar(value: item.progress, color: item.problem == nil ? Theme.accent : Theme.warning)
                    HStack {
                        Text([item.status, item.client, item.sizeLeft.map { "\(Format.bytes($0)) left" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    if let problem = item.problem { Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning) }
                }
                .swipeActions { Button(role: .destructive) { removing = item } label: { Label("Remove", systemImage: "trash") } }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .confirmationDialog("Remove \(removing?.title ?? "download")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove from queue and client", role: .destructive) { remove(blocklist: false) }
            Button("Remove and blocklist release", role: .destructive) { remove(blocklist: true) }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var all: [ActivityDownload] = []
        var problems: [String] = []
        for instance in app.configured where [.sonarr, .radarr, .lidarr].contains(instance.kind) {
            do {
                let arr = try app.client(instance)
                let records: [QueueItem]
                switch instance.kind {
                case .sonarr: records = try await SonarrClient(client: arr).queue().records
                case .radarr: records = try await RadarrClient(client: arr).queue().records
                default: records = try await LidarrClient(client: arr).queue().records
                }
                all += records.map { ActivityDownload(serviceId: instance.id, kind: instance.kind, item: $0) }
            } catch {
                problems.append("\(instance.name): \(AppState.describe(error))")
            }
        }
        items = all.sorted { ($0.problem != nil ? 0 : 1, $0.progress) > ($1.problem != nil ? 0 : 1, $1.progress) }
        errors = problems
    }

    private func remove(blocklist: Bool) {
        guard let item = removing, let instance = app.services.first(where: { $0.id == item.serviceId }) else { return }
        removing = nil
        app.perform(blocklist ? "Removed and blocklisted" : "Removed") {
            try await GenericArr(client: try app.client(instance)).removeFromQueue(item.queueId, removeFromClient: true, blocklist: blocklist)
            await load()
        }
    }
}

struct CalendarView: View {
    @Environment(AppState.self) private var app
    @State private var groups: [(day: Date, entries: [CalendarEntry])] = []
    @State private var loading = false

    var body: some View {
        List {
            if groups.isEmpty && !loading { ContentUnavailableView("Nothing in the next two weeks", systemImage: "calendar") }
            ForEach(groups, id: \.day) { group in
                Section(group.day.formatted(.dateTime.weekday(.wide).day().month())) {
                    ForEach(group.entries) { entry in
                        HStack(spacing: 12) {
                            Poster(url: entry.posterURL, width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(entry.subtitle ?? "").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if entry.kind == .episode { Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.caption) }
                                if entry.hasFile { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                            }
                        }
                    }
                }
            }
        }
        .overlay { if loading && groups.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(14 * 86_400)
        var entries: [CalendarEntry] = []
        for i in app.instances(.sonarr) { entries += ((try? await app.sonarr(i).calendar(from: start, to: end)) ?? []).compactMap(CalendarEntry.from) }
        for i in app.instances(.radarr) { entries += ((try? await app.radarr(i).calendar(from: start, to: end)) ?? []).compactMap { CalendarEntry.from($0) } }
        for i in app.instances(.lidarr) { entries += ((try? await app.lidarr(i).calendar(from: start, to: end)) ?? []).compactMap(CalendarEntry.from) }
        groups = CalendarEntry.groupedByDay(entries)
    }
}

struct WantedView: View {
    @Environment(AppState.self) private var app
    @State private var episodes: [(ServiceInstance, Episode)] = []
    @State private var movies: [(ServiceInstance, Movie)] = []
    @State private var albums: [(ServiceInstance, Album)] = []
    @State private var loading = false

    var body: some View {
        List {
            if episodes.isEmpty && movies.isEmpty && albums.isEmpty && !loading {
                ContentUnavailableView("Nothing missing", systemImage: "checkmark.seal")
            }
            if !movies.isEmpty {
                Section {
                    ForEach(movies, id: \.1.id) { instance, movie in
                        MediaRow(title: movie.title, subtitle: movie.year.map(String.init) ?? "", poster: movie.images?.poster, status: movieStatus(movie))
                            .swipeActions { searchButton { try await app.radarr(instance).search(movieIds: [movie.id]) } }
                    }
                } header: {
                    sectionHeader("Movies") { for i in app.instances(.radarr) { try await app.radarr(i).searchAllMissing() } }
                }
            }
            if !episodes.isEmpty {
                Section {
                    ForEach(episodes, id: \.1.id) { instance, episode in
                        MediaRow(title: episode.series?.title ?? "Episode", subtitle: [episode.code, episode.title].compactMap { $0 }.joined(separator: " · "),
                                 poster: episode.series?.images?.poster, status: nil)
                            .swipeActions { searchButton { try await app.sonarr(instance).searchEpisodes([episode.id]) } }
                    }
                } header: {
                    sectionHeader("Episodes") { for i in app.instances(.sonarr) { try await app.sonarr(i).command("MissingEpisodeSearch") } }
                }
            }
            if !albums.isEmpty {
                Section {
                    ForEach(albums, id: \.1.id) { instance, album in
                        MediaRow(title: album.title, subtitle: album.artist?.artistName ?? "", poster: album.images?.poster ?? album.artist?.images?.poster, status: nil)
                            .swipeActions { searchButton { try await app.lidarr(instance).searchAlbums([album.id]) } }
                    }
                } header: {
                    sectionHeader("Albums") { for i in app.instances(.lidarr) { try await app.lidarr(i).command("MissingAlbumSearch") } }
                }
            }
        }
        .overlay { if loading && episodes.isEmpty && movies.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
    }

    private func searchButton(_ action: @escaping () async throws -> Void) -> some View {
        Button { app.perform("Search started", action) } label: { Label("Search", systemImage: "magnifyingglass") }.tint(Theme.accent)
    }

    private func sectionHeader(_ title: String, searchAll: @escaping () async throws -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Search all") { app.perform("Searching all missing \(title.lowercased())", searchAll) }.font(.caption.weight(.semibold))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var e: [(ServiceInstance, Episode)] = []
        var m: [(ServiceInstance, Movie)] = []
        var a: [(ServiceInstance, Album)] = []
        for i in app.instances(.sonarr) { e += ((try? await app.sonarr(i).missing().records) ?? []).map { (i, $0) } }
        for i in app.instances(.radarr) { m += ((try? await app.radarr(i).missing().records) ?? []).map { (i, $0) } }
        for i in app.instances(.lidarr) { a += ((try? await app.lidarr(i).missing().records) ?? []).map { (i, $0) } }
        episodes = e
        movies = m
        albums = a
    }
}

struct HistoryView: View {
    @Environment(AppState.self) private var app
    @State private var records: [(ServiceKind, HistoryRecord)] = []
    @State private var loading = false

    var body: some View {
        List {
            if records.isEmpty && !loading { ContentUnavailableView("No history yet", systemImage: "clock") }
            ForEach(Array(records.enumerated()), id: \.offset) { _, entry in
                let record = entry.1
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(record.eventType)).foregroundStyle(color(record.eventType)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(record)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(record.sourceTitle ?? "").font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        Text([eventName(record.eventType), record.quality?.name, record.date?.relative].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .overlay { if loading && records.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
    }

    private func title(_ r: HistoryRecord) -> String {
        if let s = r.series { return [s.title, r.episode?.code].compactMap { $0 }.joined(separator: " ") }
        if let m = r.movie { return m.title }
        if let a = r.artist { return [a.artistName, r.album?.title].compactMap { $0 }.joined(separator: " — ") }
        return r.sourceTitle ?? "Event"
    }

    private func eventName(_ type: String?) -> String? {
        switch type {
        case "grabbed": "Grabbed"
        case "downloadFolderImported", "trackFileImported", "downloadImported": "Imported"
        case "downloadFailed": "Failed"
        case "episodeFileDeleted", "movieFileDeleted", "trackFileDeleted": "Deleted"
        case "episodeFileRenamed", "movieFileRenamed", "trackFileRenamed": "Renamed"
        default: type
        }
    }

    private func icon(_ type: String?) -> String {
        switch type {
        case "grabbed": "arrow.down.circle"
        case "downloadFailed": "xmark.octagon"
        case let t? where t.contains("Deleted"): "trash"
        case let t? where t.contains("Imported"): "checkmark.circle"
        default: "clock"
        }
    }

    private func color(_ type: String?) -> Color {
        switch type {
        case "downloadFailed": Theme.error
        case let t? where t.contains("Imported"): Theme.ok
        default: Theme.textSecondary
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var out: [(ServiceKind, HistoryRecord)] = []
        for i in app.instances(.sonarr) { out += ((try? await app.sonarr(i).history().records) ?? []).map { (.sonarr, $0) } }
        for i in app.instances(.radarr) { out += ((try? await app.radarr(i).history().records) ?? []).map { (.radarr, $0) } }
        for i in app.instances(.lidarr) { out += ((try? await app.lidarr(i).history().records) ?? []).map { (.lidarr, $0) } }
        records = out.sorted { ($0.1.date ?? .distantPast) > ($1.1.date ?? .distantPast) }
    }
}
