import StreameroKit
import SwiftUI

struct IndexersView: View {
    var body: some View {
        InstanceScope(kind: .prowlarr) { IndexersList(instance: $0) }
            .navigationTitle("Indexers")
    }
}

struct IndexersList: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var indexers: [Indexer] = []
    @State private var statuses: [Int: IndexerStatus] = [:]
    @State private var stats: [Int: IndexerStats.Entry] = [:]
    @State private var apps: [ProwlarrApplication] = []
    @State private var testing: Set<Int> = []
    @State private var loading = false

    var body: some View {
        List {
            Section {
                NavigationLink { ReleaseSearchView(instance: instance, indexers: indexers) } label: { Label("Search all indexers", systemImage: "magnifyingglass") }
                Button { app.perform("Testing all indexers") { try await app.prowlarr(instance).testAll(); await load() } } label: { Label("Test all", systemImage: "checkmark.shield") }
                Button { app.perform("Syncing apps") { try await app.prowlarr(instance).syncApplications() } } label: { Label("Sync to Sonarr/Radarr/Lidarr", systemImage: "arrow.triangle.2.circlepath") }
            }
            Section("Indexers") {
                ForEach(indexers.sorted { ($0.priority ?? 25, $0.name) < ($1.priority ?? 25, $1.name) }) { indexer in
                    let status = statuses[indexer.id]
                    let failing = status?.disabledTill.map { $0 > Date() } ?? false
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            StatusDot(color: !indexer.enable ? Theme.textSecondary : failing ? Theme.error : Theme.ok)
                            Text(indexer.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            if testing.contains(indexer.id) { ProgressView() }
                            Pill(text: (indexer.protocol ?? "").capitalized)
                        }
                        Text([indexer.privacy?.capitalized, indexer.priority.map { "Priority \($0)" }, stats[indexer.id].map { "\($0.numberOfQueries ?? 0) queries · \($0.numberOfGrabs ?? 0) grabs" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        if failing, let until = status?.disabledTill {
                            Text("Disabled after failures until \(until.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(Theme.error)
                        }
                    }
                    .swipeActions {
                        Button { test(indexer) } label: { Label("Test", systemImage: "checkmark.shield") }.tint(Theme.accent)
                        Button {
                            app.perform(indexer.enable ? "Disabled \(indexer.name)" : "Enabled \(indexer.name)") {
                                try await app.prowlarr(instance).setEnabled(indexerId: indexer.id, !indexer.enable)
                                await load()
                            }
                        } label: { Label(indexer.enable ? "Disable" : "Enable", systemImage: indexer.enable ? "pause.circle" : "play.circle") }
                    }
                }
            }
            if !apps.isEmpty {
                Section("Connected apps") {
                    ForEach(apps) { a in LabeledContent(a.name ?? a.implementation ?? "App", value: a.syncLevel ?? "") }
                }
            }
        }
        .overlay { if loading && indexers.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = try? app.prowlarr(instance) else { return }
        do { indexers = try await client.indexers() } catch { app.show(AppState.describe(error), error: true) }
        statuses = Dictionary(((try? await client.indexerStatuses()) ?? []).map { ($0.indexerId, $0) }, uniquingKeysWith: { a, _ in a })
        stats = Dictionary(((try? await client.stats().indexers) ?? []).map { ($0.indexerId, $0) }, uniquingKeysWith: { a, _ in a })
        apps = (try? await client.applications()) ?? []
    }

    private func test(_ indexer: Indexer) {
        testing.insert(indexer.id)
        Task {
            defer { testing.remove(indexer.id) }
            do {
                try await app.prowlarr(instance).test(indexerId: indexer.id)
                app.show("\(indexer.name) works")
            } catch {
                app.show("\(indexer.name): \(AppState.describe(error))", error: true)
            }
        }
    }
}

struct ReleaseSearchView: View {
    var instance: ServiceInstance
    var indexers: [Indexer]
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var results: [ReleaseResult] = []
    @State private var loading = false
    @State private var grabbing: ReleaseResult?

    var body: some View {
        List {
            if results.isEmpty && !loading { ContentUnavailableView("Search releases", systemImage: "magnifyingglass", description: Text("Searches every enabled indexer in Prowlarr.")) }
            ForEach(results) { release in
                Button { grabbing = release } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(release.title ?? "Release").font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                        HStack(spacing: 8) {
                            Text(release.indexer ?? "").font(.caption2.weight(.semibold))
                            Text(Format.bytes(release.size)).font(.caption2)
                            if let seeders = release.seeders { Label("\(seeders)", systemImage: "arrow.up").font(.caption2).foregroundStyle(seeders > 0 ? Theme.ok : Theme.error) }
                            if let date = release.publishDate { Text(date.relative).font(.caption2) }
                        }
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .overlay { if loading { ProgressView("Searching…") } }
        .navigationTitle("Release search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title, e.g. Big Buck Bunny 1080p")
        .onSubmit(of: .search) { Task { await search() } }
        .confirmationDialog("Send to download client?", isPresented: Binding(get: { grabbing != nil }, set: { if !$0 { grabbing = nil } }), titleVisibility: .visible) {
            Button("Download") {
                guard let release = grabbing else { return }
                app.perform("Sent to download client") { try await app.prowlarr(instance).grab(release) }
            }
        } message: {
            Text(grabbing?.title ?? "")
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            results = try await app.prowlarr(instance).search(text, indexerIds: indexers.filter(\.enable).map(\.id))
                .sorted { ($0.seeders ?? 0) > ($1.seeders ?? 0) }
        } catch {
            app.show(AppState.describe(error), error: true)
        }
    }
}
