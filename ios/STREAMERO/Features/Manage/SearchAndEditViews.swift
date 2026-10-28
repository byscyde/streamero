import StreameroKit
import SwiftUI

/// Interactive search: every release the indexers return, with the reasons Sonarr/Radarr/Lidarr would reject it.
struct ReleasesSheet: View {
    var instance: ServiceInstance
    var target: ReleaseTarget
    var title: String
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var releases: [ArrRelease] = []
    @State private var loading = true
    @State private var error: String?
    @State private var sort: Sort = .decision
    @State private var grabbing: ArrRelease?

    enum Sort: String, CaseIterable, Identifiable { case decision = "Best", seeders = "Seeders", size = "Size", age = "Newest"; var id: String { rawValue } }

    var body: some View {
        List {
            Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            if let error { ErrorStateView(message: error) { Task { await load() } } }
            if !loading && error == nil && releases.isEmpty { ContentUnavailableView("No releases found", systemImage: "magnifyingglass") }
            ForEach(sorted) { release in
                Button { grabbing = release } label: { ReleaseRow(release: release) }
                    .buttonStyle(.plain)
            }
        }
        .overlay {
            if loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Asking every indexer… this can take a minute.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task { await load() }
        .confirmationDialog(grabbing?.title ?? "", isPresented: Binding(get: { grabbing != nil }, set: { if !$0 { grabbing = nil } }), titleVisibility: .visible) {
            if let release = grabbing {
                Button(release.approved ? "Download" : "Download anyway") {
                    app.perform("Sent to download client") { try await app.arr(instance).grab(release) }
                }
            }
        } message: {
            if let release = grabbing, !release.rejections.isEmpty { Text(release.rejections.joined(separator: "\n")) }
        }
    }

    private var sorted: [ArrRelease] {
        switch sort {
        case .decision: releases
        case .seeders: releases.sorted { ($0.seeders ?? -1) > ($1.seeders ?? -1) }
        case .size: releases.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case .age: releases.sorted { ($0.ageHours ?? .infinity) < ($1.ageHours ?? .infinity) }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { releases = try await app.arr(instance).releases(for: target); error = nil } catch { self.error = AppState.describe(error) }
    }
}

struct ReleaseRow: View {
    var release: ArrRelease
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Image(systemName: release.approved ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(release.approved ? Theme.ok : Theme.warning)
                Text(release.title).font(.subheadline).lineLimit(3)
            }
            HStack(spacing: 8) {
                if let quality = release.quality { Pill(text: quality, color: Theme.accent) }
                Text(Format.bytes(release.size))
                if let age = release.ageText { Text(age) }
                if release.`protocol` == "torrent" { Text("\(release.seeders ?? 0)↑ \(release.leechers ?? 0)↓") }
                if let score = release.customFormatScore, score != 0 { Text("CF \(score)") }
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            Text([release.indexer, release.languages.isEmpty ? nil : release.languages.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(Theme.textSecondary)
            ForEach(release.rejections, id: \.self) { Text($0).font(.caption2).foregroundStyle(Theme.warning) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Edit sheet for a movie, series or artist: profiles, tags, monitoring and type-specific options.
struct ItemEditView: View {
    var instance: ServiceInstance
    /// "movie/3", "series/12" or "artist/5".
    var path: String
    var onSave: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var raw: JSONValue?
    @State private var edit: ItemEdit?
    @State private var profiles: [QualityProfile] = []
    @State private var metadataProfiles: [MetadataProfile] = []
    @State private var tags: [ArrTag] = []
    @State private var saving = false

    var body: some View {
        Form {
            if let binding = Binding($edit) {
                Section {
                    Toggle("Monitored", isOn: binding.monitored)
                    Picker("Quality profile", selection: binding.qualityProfileId) {
                        ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if instance.kind == .lidarr {
                        Picker("Metadata profile", selection: binding.metadataProfileId) {
                            ForEach(metadataProfiles) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    if instance.kind == .radarr {
                        Picker("Minimum availability", selection: binding.minimumAvailability) {
                            Text("Announced").tag(Optional("announced"))
                            Text("In cinemas").tag(Optional("inCinemas"))
                            Text("Released").tag(Optional("released"))
                        }
                    }
                    if instance.kind == .sonarr {
                        Picker("Series type", selection: binding.seriesType) {
                            Text("Standard").tag(Optional("standard"))
                            Text("Daily").tag(Optional("daily"))
                            Text("Anime").tag(Optional("anime"))
                        }
                        Toggle("Season folders", isOn: Binding(get: { edit?.seasonFolder ?? true }, set: { edit?.seasonFolder = $0 }))
                    }
                }
                if instance.kind == .sonarr, let seasons = edit?.monitoredSeasons, !seasons.isEmpty {
                    Section("Monitored seasons") {
                        ForEach(seasons.keys.sorted(by: >), id: \.self) { number in
                            Toggle(number == 0 ? "Specials" : "Season \(number)", isOn: Binding(get: { edit?.monitoredSeasons[number] ?? false }, set: { edit?.monitoredSeasons[number] = $0 }))
                        }
                    }
                }
                Section("Tags") {
                    if tags.isEmpty { Text("No tags. Create them under Manage → Tags.").font(.footnote).foregroundStyle(Theme.textSecondary) }
                    ForEach(tags) { tag in
                        Toggle(tag.label, isOn: Binding(get: { edit?.tags.contains(tag.id) ?? false }, set: { on in
                            if on { edit?.tags.append(tag.id) } else { edit?.tags.removeAll { $0 == tag.id } }
                        }))
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button { save() } label: { if saving { ProgressView() } else { Text("Save") } }.disabled(edit == nil || saving)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let arr = try app.arr(instance)
            let item = try await arr.editableItem(path)
            profiles = (try? await arr.qualityProfiles()) ?? []
            tags = (try? await arr.tags()) ?? []
            if instance.kind == .lidarr { metadataProfiles = (try? await app.lidarr(instance).metadataProfiles()) ?? [] }
            raw = item
            edit = ItemEdit(raw: item)
        } catch {
            app.show(AppState.describe(error), error: true)
            dismiss()
        }
    }

    private func save() {
        guard let raw, let edit else { return }
        saving = true
        app.perform("Saved") {
            defer { saving = false }
            try await app.arr(instance).saveItem(path, raw: raw, edit: edit)
            onSave()
            dismiss()
        }
    }
}

/// What an interactive-search sheet is opened for.
struct ReleaseQuery: Identifiable {
    let id = UUID()
    var target: ReleaseTarget
    var title: String
}

enum DetailSheet: String, Identifiable {
    case releases, edit
    var id: String { rawValue }
}
