import StreameroKit
import SwiftUI

@MainActor
@Observable
final class DashboardModel {
    var probes: [ProbeResult] = []
    var sessions: [JellyfinSession] = []
    var pendingRequests = 0
    var openIssues = 0
    var downloads: [ActivityDownload] = []
    var disks: [DiskSpace] = []
    var upcoming: [CalendarEntry] = []
    var counts: ItemCounts?
    var loading = false
    var lastUpdated: Date?

    func load(_ app: AppState) async {
        guard !loading else { return }
        loading = true
        defer { loading = false; lastUpdated = Date() }
        let targets: [(ServiceInstance, ServiceClient)] = app.configured.compactMap { instance in
            (try? app.client(instance)).map { (instance, $0) }
        }

        async let probes: [ProbeResult] = Self.probeAll(targets)
        async let sessions = loadSessions(app)
        async let requests = loadRequests(app)
        async let activity = loadActivity(app)
        async let counts = loadCounts(app)

        self.probes = await probes
        self.sessions = await sessions
        (self.pendingRequests, self.openIssues) = await requests
        (self.downloads, self.disks, self.upcoming) = await activity
        self.counts = await counts
    }

    nonisolated private static func probeAll(_ targets: [(ServiceInstance, ServiceClient)]) async -> [ProbeResult] {
        await withTaskGroup(of: ProbeResult.self) { group in
            for (instance, client) in targets {
                group.addTask { await ServiceProbe.probe(instance, client: client) }
            }
            var out: [ProbeResult] = []
            for await result in group { out.append(result) }
            return out.sorted { $0.instance.kind.rawValue < $1.instance.kind.rawValue }
        }
    }

    private func loadSessions(_ app: AppState) async -> [JellyfinSession] {
        guard let instance = app.first(.jellyfin), let client = try? app.jellyfin(instance) else { return [] }
        return ((try? await client.sessions(activeWithinSeconds: 120)) ?? []).filter(\.isPlaying)
    }

    private func loadCounts(_ app: AppState) async -> ItemCounts? {
        guard let instance = app.first(.jellyfin), let client = try? app.jellyfin(instance) else { return nil }
        return try? await client.itemCounts()
    }

    private func loadRequests(_ app: AppState) async -> (Int, Int) {
        var pending = 0
        var issues = 0
        for instance in app.instances(.seerr) {
            guard let client = try? app.seerr(instance) else { continue }
            pending += (try? await client.counts().pending) ?? 0
            issues += (try? await client.issues(openOnly: true, take: 1).pageInfo?.results) ?? 0
        }
        return (pending, issues)
    }

    private func loadActivity(_ app: AppState) async -> ([ActivityDownload], [DiskSpace], [CalendarEntry]) {
        var downloads: [ActivityDownload] = []
        var disks: [DiskSpace] = []
        var upcoming: [CalendarEntry] = []
        let start = Date()
        let end = start.addingTimeInterval(7 * 86_400)
        for instance in app.instances(.sonarr) {
            guard let c = try? app.sonarr(instance) else { continue }
            downloads += ((try? await c.queue().records) ?? []).map { ActivityDownload(serviceId: instance.id, kind: .sonarr, item: $0) }
            disks += (try? await c.diskSpace()) ?? []
            upcoming += ((try? await c.calendar(from: start, to: end)) ?? []).compactMap(CalendarEntry.from)
        }
        for instance in app.instances(.radarr) {
            guard let c = try? app.radarr(instance) else { continue }
            downloads += ((try? await c.queue().records) ?? []).map { ActivityDownload(serviceId: instance.id, kind: .radarr, item: $0) }
            disks += (try? await c.diskSpace()) ?? []
            upcoming += ((try? await c.calendar(from: start, to: end)) ?? []).compactMap { CalendarEntry.from($0) }
        }
        for instance in app.instances(.lidarr) {
            guard let c = try? app.lidarr(instance) else { continue }
            downloads += ((try? await c.queue().records) ?? []).map { ActivityDownload(serviceId: instance.id, kind: .lidarr, item: $0) }
            disks += (try? await c.diskSpace()) ?? []
            upcoming += ((try? await c.calendar(from: start, to: end)) ?? []).compactMap(CalendarEntry.from)
        }
        return (downloads, DiskSummary.unique(disks), upcoming.sorted { $0.date < $1.date })
    }

    var issues: [HealthIssue] {
        HealthIssue.sorted(probes.flatMap { probe in
            probe.error.map { [HealthIssue(service: probe.instance.name, severity: .error, message: $0)] } ?? probe.issues.filter { $0.severity >= .warning }
        })
    }
}

struct DashboardView: View {
    @Binding var tab: AppTab
    @Environment(AppState.self) private var app
    @State private var model = DashboardModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                servicesGrid
                summaryRow
                if !model.sessions.isEmpty { nowPlaying }
                if !model.issues.isEmpty { healthCard }
                if !model.downloads.isEmpty { downloadsCard }
                if !model.disks.isEmpty { disksCard }
                if !model.upcoming.isEmpty { upcomingCard }
                if let counts = model.counts { libraryCounts(counts) }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle("Streamero")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { BrandMark(size: 28) }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
        }
        .refreshable { await model.load(app) }
        .task {
            // Refresh every 30 seconds while the dashboard is visible.
            while !Task.isCancelled {
                await model.load(app)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var servicesGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(model.probes) { probe in
                NavigationLink { destination(for: probe.instance) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: Theme.icon(probe.instance.kind)).foregroundStyle(Theme.accent)
                            Spacer()
                            StatusDot(color: Theme.color(probe.worstSeverity))
                        }
                        Text(probe.instance.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(probe.error == nil ? (probe.version.map { "v\($0)" } ?? "Online") : "Offline")
                            .font(.caption).foregroundStyle(probe.error == nil ? Theme.textSecondary : Theme.error)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if model.probes.isEmpty && model.loading {
                ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 14).fill(Theme.surface).frame(height: 84) }
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            stat("Streams", "\(model.sessions.count)", "play.circle.fill") {}
            stat("Requests", "\(model.pendingRequests)", "tray.full.fill") { tab = .requests }
            stat("Downloads", "\(model.downloads.count)", "arrow.down.circle.fill") { tab = .activity }
        }
    }

    private func stat(_ title: String, _ value: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol).foregroundStyle(Theme.accent)
                Text(value).font(.system(.title2, design: .monospaced).weight(.bold))
                Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var nowPlaying: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                header("Now playing", destination: AnyView(JellyfinSessionsView()))
                ForEach(model.sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(session.nowPlayingItem?.displayTitle ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if session.isTranscoding { Pill(text: "Transcode", color: Theme.warning) } else { Pill(text: "Direct", color: Theme.ok) }
                        }
                        Text([session.userName, session.deviceName, session.client].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        ProgressBar(value: session.progress, color: session.playState?.isPaused == true ? Theme.textSecondary : Theme.accent)
                    }
                }
            }
        }
    }

    private var healthCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                header("Needs attention", destination: AnyView(SystemHealthView()))
                ForEach(model.issues.prefix(6)) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        StatusDot(color: Theme.color(issue.severity)).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.service).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                            Text(issue.message).font(.footnote)
                        }
                    }
                }
            }
        }
    }

    private var downloadsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                header("Downloading", destination: AnyView(QueueView()))
                ForEach(model.downloads.prefix(4)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text(item.timeLeft ?? Format.percent(item.progress)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        ProgressBar(value: item.progress, color: item.problem == nil ? Theme.accent : Theme.warning)
                    }
                }
            }
        }
    }

    private var disksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Storage").font(Theme.titleFont)
                ForEach(model.disks, id: \.self) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(disk.label ?? disk.path ?? "Disk").font(.subheadline).lineLimit(1)
                            Spacer()
                            Text("\(Format.bytes(disk.freeSpace)) free of \(Format.bytes(disk.totalSpace))").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        ProgressBar(value: disk.usedFraction, color: disk.usedFraction > 0.9 ? Theme.error : disk.usedFraction > 0.8 ? Theme.warning : Theme.ok)
                    }
                }
            }
        }
    }

    private var upcomingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                header("Coming up", destination: AnyView(CalendarView()))
                ForEach(model.upcoming.prefix(5)) { entry in
                    HStack(spacing: 10) {
                        Poster(url: entry.posterURL, width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(entry.subtitle ?? "").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Text(entry.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func libraryCounts(_ counts: ItemCounts) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Jellyfin library").font(Theme.titleFont)
                HStack {
                    count("Movies", counts.movieCount)
                    count("Series", counts.seriesCount)
                    count("Episodes", counts.episodeCount)
                    count("Albums", counts.albumCount)
                }
            }
        }
    }

    private func count(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading) {
            Text("\(value ?? 0)").font(.system(.headline, design: .monospaced))
            Text(title).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ title: String, destination: AnyView) -> some View {
        HStack {
            Text(title).font(Theme.titleFont)
            Spacer()
            NavigationLink { destination } label: { Text("More").font(.caption.weight(.semibold)) }
        }
    }

    @ViewBuilder private func destination(for instance: ServiceInstance) -> some View {
        switch instance.kind {
        case .jellyfin: JellyfinHomeView()
        case .seerr: RequestsView()
        case .sonarr: SeriesListView()
        case .radarr: MoviesListView()
        case .lidarr: ArtistsListView()
        case .prowlarr: IndexersView()
        case .bazarr: SubtitlesView()
        }
    }
}

struct SystemHealthView: View {
    @Environment(AppState.self) private var app
    @State private var probes: [ProbeResult] = []
    @State private var loading = true

    var body: some View {
        List {
            ForEach(probes) { probe in
                Section {
                    if let error = probe.error {
                        Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.error)
                    } else if probe.issues.isEmpty {
                        Label("No issues", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    } else {
                        ForEach(probe.issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(issue.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.color(issue.severity))
                                if let wiki = issue.wikiURL { Link("Help", destination: wiki).font(.caption) }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(probe.instance.name)
                        Spacer()
                        if let version = probe.version { Text("v\(version)") }
                    }
                }
            }
        }
        .overlay { if loading && probes.isEmpty { ProgressView() } }
        .navigationTitle("System health")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var out: [ProbeResult] = []
        for instance in app.configured {
            if let client = try? app.client(instance) { out.append(await ServiceProbe.probe(instance, client: client)) }
        }
        probes = out
    }
}
