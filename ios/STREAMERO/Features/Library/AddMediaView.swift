import StreameroKit
import SwiftUI

/// Search TMDB/TVDB/MusicBrainz through Radarr, Sonarr or Lidarr and add the result.
struct AddMediaView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var results: [LookupItem] = []
    @State private var loading = false
    @State private var selected: LookupItem?

    struct LookupItem: Identifiable, Hashable {
        var id: Int
        var raw: JSONValue
        var title: String
        var subtitle: String
        var poster: URL?
        var overview: String?
        var inLibrary: Bool
    }

    var body: some View {
        List {
            if results.isEmpty && !loading {
                ContentUnavailableView(query.isEmpty ? "Search to add" : "No results", systemImage: "magnifyingglass",
                                       description: Text(query.isEmpty ? "Type a title above." : "Try another spelling."))
            }
            ForEach(results) { item in
                Button { if !item.inLibrary { selected = item } } label: {
                    HStack(spacing: 12) {
                        Poster(url: item.poster, width: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            Text(item.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: item.inLibrary ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(item.inLibrary ? Theme.ok : Theme.accent)
                    }
                }
                .disabled(item.inLibrary)
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle("Add to \(instance.name)")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await search()
        }
        .sheet(item: $selected) { item in
            NavigationStack { AddOptionsView(instance: instance, item: item) }
                .presentationDetents([.medium, .large])
        }
    }

    private var prompt: String {
        switch instance.kind {
        case .sonarr: "Series title"
        case .lidarr: "Artist name"
        default: "Movie title"
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { results = []; return }
        loading = true
        defer { loading = false }
        do {
            switch instance.kind {
            case .radarr:
                results = try await app.radarr(instance).lookup(term).enumerated().compactMap { index, raw in
                    guard let movie = try? raw.decode(Movie.self) else { return nil }
                    return LookupItem(id: movie.tmdbId ?? index, raw: raw, title: movie.title,
                                      subtitle: [movie.year.map(String.init), movie.studio].compactMap { $0 }.joined(separator: " · "),
                                      poster: movie.images?.poster, overview: movie.overview, inLibrary: movie.isInLibrary)
                }
            case .sonarr:
                results = try await app.sonarr(instance).lookup(term).enumerated().compactMap { index, raw in
                    guard let series = try? raw.decode(Series.self) else { return nil }
                    return LookupItem(id: series.tvdbId ?? index, raw: raw, title: series.title,
                                      subtitle: [series.year.map(String.init), series.network, series.seasons.map { "\($0.filter { $0.seasonNumber > 0 }.count) seasons" }].compactMap { $0 }.joined(separator: " · "),
                                      poster: series.images?.poster, overview: series.overview, inLibrary: series.isInLibrary)
                }
            case .lidarr:
                results = try await app.lidarr(instance).lookup(term).enumerated().compactMap { index, raw in
                    guard let artist = try? raw.decode(Artist.self) else { return nil }
                    return LookupItem(id: index, raw: raw, title: artist.artistName, subtitle: (artist.genres ?? []).prefix(2).joined(separator: ", "),
                                      poster: artist.images?.poster, overview: artist.overview, inLibrary: artist.isInLibrary)
                }
            default:
                results = []
            }
        } catch {
            app.show(AppState.describe(error), error: true)
        }
    }
}

struct AddOptionsView: View {
    var instance: ServiceInstance
    var item: AddMediaView.LookupItem
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [QualityProfile] = []
    @State private var metadataProfiles: [MetadataProfile] = []
    @State private var folders: [RootFolder] = []
    @State private var profileId: Int?
    @State private var metadataProfileId: Int?
    @State private var folder: String?
    @State private var searchNow = true
    @State private var monitor = "all"
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Poster(url: item.poster, width: 70)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(Theme.titleFont)
                        Text(item.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let overview = item.overview { Text(overview).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(5) }
            }
            Section("Options") {
                Picker("Quality profile", selection: $profileId) {
                    ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                if instance.kind == .lidarr {
                    Picker("Metadata profile", selection: $metadataProfileId) {
                        ForEach(metadataProfiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Picker("Root folder", selection: $folder) {
                    ForEach(folders) { f in Text("\(f.path) (\(Format.bytes(f.freeSpace)) free)").tag(Optional(f.path)) }
                }
                if instance.kind == .sonarr {
                    Picker("Monitor", selection: $monitor) {
                        Text("All episodes").tag("all")
                        Text("Future episodes").tag("future")
                        Text("Missing episodes").tag("missing")
                        Text("First season").tag("firstSeason")
                        Text("Latest season").tag("latestSeason")
                        Text("None").tag("none")
                    }
                }
                Toggle("Start searching now", isOn: $searchNow)
            }
        }
        .navigationTitle("Add")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button { add() } label: { if adding { ProgressView() } else { Text("Add") } }
                    .disabled(profileId == nil || folder == nil || adding || (instance.kind == .lidarr && metadataProfileId == nil))
            }
        }
        .task { await loadOptions() }
    }

    private func loadOptions() async {
        do {
            let arr = GenericArr(client: try app.client(instance))
            profiles = try await arr.qualityProfiles()
            folders = try await arr.rootFolders()
            if instance.kind == .lidarr { metadataProfiles = try await app.lidarr(instance).metadataProfiles() }
            profileId = profileId ?? profiles.first?.id
            folder = folder ?? folders.first?.path
            metadataProfileId = metadataProfileId ?? metadataProfiles.first?.id
        } catch {
            app.show(AppState.describe(error), error: true)
        }
    }

    private func add() {
        guard let profileId, let folder else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                switch instance.kind {
                case .radarr: try await app.radarr(instance).add(item.raw, qualityProfileId: profileId, rootFolderPath: folder, searchNow: searchNow)
                case .sonarr: try await app.sonarr(instance).add(item.raw, qualityProfileId: profileId, rootFolderPath: folder, monitor: monitor, searchNow: searchNow)
                case .lidarr: try await app.lidarr(instance).add(item.raw, qualityProfileId: profileId, metadataProfileId: metadataProfileId ?? 1, rootFolderPath: folder, searchNow: searchNow)
                default: break
                }
                app.show("Added \(item.title)")
                dismiss()
            } catch {
                app.show(AppState.describe(error), error: true)
            }
        }
    }
}
