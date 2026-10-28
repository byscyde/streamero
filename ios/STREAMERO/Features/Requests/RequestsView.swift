import StreameroKit
import SwiftUI

/// Chooses which configured instance of a service a screen works with.
struct InstanceScope<Content: View>: View {
    var kind: ServiceKind
    @ViewBuilder var content: (ServiceInstance) -> Content
    @Environment(AppState.self) private var app
    @State private var selection: UUID?

    var body: some View {
        let instances = app.instances(kind)
        if let current = instances.first(where: { $0.id == selection }) ?? instances.first {
            VStack(spacing: 0) {
                if instances.count > 1 {
                    InstancePicker(instances: instances, selection: Binding(get: { current.id }, set: { selection = $0 }))
                        .padding(.horizontal).padding(.vertical, 8)
                }
                content(current).id(current.id)
            }
        } else {
            NotConfiguredView(kind: kind)
        }
    }
}

struct RequestsView: View {
    var body: some View {
        InstanceScope(kind: .seerr) { instance in RequestsList(instance: instance) }
            .navigationTitle("Requests")
            .background(Theme.background)
    }
}

struct RequestsList: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var filter: SeerrRequestFilter = .pending
    @State private var requests: [SeerrRequest] = []
    @State private var error: String?
    @State private var loading = false
    @State private var page: Page?

    enum Page: Hashable { case issues, users, jobs }

    var body: some View {
        List {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach([SeerrRequestFilter.pending, .approved, .processing, .available, .all]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if let error, requests.isEmpty {
                ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
            } else if requests.isEmpty && !loading {
                ContentUnavailableView("No \(filter.title.lowercased()) requests", systemImage: "tray").listRowBackground(Color.clear)
            }
            ForEach(requests) { request in
                NavigationLink { RequestDetailView(instance: instance, request: request, onChange: { Task { await load() } }) } label: {
                    RequestRow(instance: instance, request: request)
                }
                .swipeActions(edge: .leading) {
                    if request.requestStatus == .pending {
                        Button { act("Approved") { try await $0.approve(request.id) } } label: { Label("Approve", systemImage: "checkmark") }.tint(Theme.ok)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if request.requestStatus == .pending {
                        Button { act("Declined") { try await $0.decline(request.id) } } label: { Label("Decline", systemImage: "xmark") }.tint(Theme.warning)
                    }
                    Button(role: .destructive) { act("Request deleted") { try await $0.delete(request.id) } } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .overlay { if loading && requests.isEmpty { ProgressView() } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { page = .issues } label: { Label("Issues", systemImage: "exclamationmark.bubble") }
                    Button { page = .users } label: { Label("Users & permissions", systemImage: "person.2") }
                    Button { page = .jobs } label: { Label("Jobs & sync", systemImage: "clock.arrow.2.circlepath") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Manage requests server")
                NavigationLink { DiscoverView(instance: instance) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Discover and request")
            }
        }
        .navigationDestination(item: $page) { page in
            switch page {
            case .issues: IssuesView(instance: instance)
            case .users: SeerrUsersView(instance: instance)
            case .jobs: SeerrJobsView(instance: instance)
            }
        }
        .refreshable { await load() }
        .task(id: filter) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            requests = try await app.seerr(instance).requests(filter: filter, take: 50).results
            error = nil
        } catch { self.error = AppState.describe(error) }
    }

    private func act(_ message: String, _ action: @escaping (SeerrClient) async throws -> Void) {
        app.perform(message) {
            try await action(try app.seerr(instance))
            await load()
        }
    }
}

struct RequestRow: View {
    var instance: ServiceInstance
    var request: SeerrRequest
    @Environment(AppState.self) private var app
    @State private var title: SeerrTitle?

    var body: some View {
        HStack(spacing: 12) {
            Poster(url: title?.posterURL, width: 46, symbol: request.isMovie ? "film" : "tv")
            VStack(alignment: .leading, spacing: 4) {
                Text(title?.title ?? "…").font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([title?.year, request.isMovie ? "Movie" : seasonsText, request.is4k == true ? "4K" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    Pill(text: request.requestStatus.title, color: color(request.requestStatus))
                    if request.requestStatus == .approved { Pill(text: request.media?.mediaStatus.title ?? "", color: Theme.textSecondary) }
                }
                Text("\(request.requestedBy?.name ?? "Someone") · \(request.createdAt?.relative ?? "")").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .task(id: request.id) {
            title = try? await app.seerr(instance).title(for: request)
        }
    }

    private var seasonsText: String {
        let seasons = request.seasons?.map(\.seasonNumber).sorted() ?? []
        return seasons.isEmpty ? "Series" : "Seasons " + seasons.map(String.init).joined(separator: ", ")
    }

    private func color(_ status: SeerrRequestStatus) -> Color {
        switch status {
        case .pending: Theme.warning
        case .approved, .completed: Theme.ok
        case .declined, .failed: Theme.error
        }
    }
}

struct RequestDetailView: View {
    var instance: ServiceInstance
    var request: SeerrRequest
    var onChange: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title: SeerrTitle?
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Poster(url: title?.posterURL, width: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title?.title ?? "…").font(.system(.title3, design: .monospaced).weight(.bold))
                        if let year = title?.year { Text(year).foregroundStyle(Theme.textSecondary) }
                        Pill(text: request.requestStatus.title)
                        Pill(text: request.media?.mediaStatus.title ?? "Unknown")
                    }
                }
                if let overview = title?.overview, !overview.isEmpty { Text(overview).font(.footnote).foregroundStyle(Theme.textSecondary) }
            }
            Section("Request") {
                LabeledContent("Requested by", value: request.requestedBy?.name ?? "—")
                if let date = request.createdAt { LabeledContent("Requested", value: date.formatted(date: .abbreviated, time: .shortened)) }
                if let modified = request.modifiedBy { LabeledContent("Handled by", value: modified.name) }
                LabeledContent("Type", value: request.isMovie ? "Movie" : "Series")
                if let seasons = request.seasons, !seasons.isEmpty {
                    LabeledContent("Seasons", value: seasons.map { String($0.seasonNumber) }.joined(separator: ", "))
                }
                if request.is4k == true { LabeledContent("Quality", value: "4K") }
            }
            Section {
                if request.requestStatus == .pending {
                    Button { act("Approved") { try await $0.approve(request.id) } } label: { Label("Approve", systemImage: "checkmark.circle.fill") }
                        .foregroundStyle(Theme.ok)
                    Button { act("Declined") { try await $0.decline(request.id) } } label: { Label("Decline", systemImage: "xmark.circle.fill") }
                        .foregroundStyle(Theme.warning)
                }
                if request.requestStatus == .failed {
                    Button { act("Retrying") { try await $0.retry(request.id) } } label: { Label("Retry", systemImage: "arrow.clockwise") }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete request", systemImage: "trash") }
            }
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .task { title = try? await app.seerr(instance).title(for: request) }
        .confirmationDialog("Delete this request?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { act("Request deleted") { try await $0.delete(request.id) } }
        }
    }

    private func act(_ message: String, _ action: @escaping (SeerrClient) async throws -> Void) {
        app.perform(message) {
            try await action(try app.seerr(instance))
            onChange()
            dismiss()
        }
    }
}

struct DiscoverView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var results: [SeerrSearchResult] = []
    @State private var loading = false
    @State private var requested: Set<Int> = []

    var body: some View {
        List {
            if results.isEmpty && !loading {
                ContentUnavailableView.search(text: query)
            }
            ForEach(results) { item in
                HStack(spacing: 12) {
                    Poster(url: item.posterURL, width: 46, symbol: item.mediaType == "movie" ? "film" : "tv")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text([item.year, item.mediaType == "movie" ? "Movie" : "Series"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        if let status = item.mediaInfo?.mediaStatus, status != .unknown {
                            Pill(text: status.title, color: status == .available ? Theme.ok : Theme.warning)
                        }
                    }
                    Spacer()
                    if requested.contains(item.id) || (item.mediaInfo?.mediaStatus ?? .unknown) != .unknown {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    } else {
                        Button("Request") { request(item) }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
        .overlay { if loading && results.isEmpty { ProgressView() } }
        .navigationTitle(query.isEmpty ? "Trending" : "Search")
        .searchable(text: $query, prompt: "Movies and series")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 400))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = try? app.seerr(instance) else { return }
        let text = query.trimmingCharacters(in: .whitespaces)
        do {
            if text.isEmpty {
                results = try await client.trending()
            } else {
                results = try await client.search(text)
            }
        } catch {
            results = []
            app.show(AppState.describe(error), error: true)
        }
    }

    private func request(_ item: SeerrSearchResult) {
        app.perform("Requested \(item.displayTitle)") {
            try await app.seerr(instance).request(item)
            requested.insert(item.id)
        }
    }
}

struct IssuesView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var issues: [SeerrIssue] = []
    @State private var openOnly = true
    @State private var loading = false

    var body: some View {
        List {
            Toggle("Open only", isOn: $openOnly)
            if issues.isEmpty && !loading { ContentUnavailableView("No issues", systemImage: "checkmark.bubble") }
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Pill(text: issue.typeTitle, color: Theme.warning)
                        if let season = issue.problemSeason, season > 0 { Text("S\(season)\(issue.problemEpisode.map { $0 > 0 ? "E\($0)" : "" } ?? "")").font(.caption) }
                        Spacer()
                        Text(issue.isOpen ? "Open" : "Resolved").font(.caption).foregroundStyle(issue.isOpen ? Theme.warning : Theme.ok)
                    }
                    if let message = issue.comments?.first?.message { Text(message).font(.subheadline) }
                    Text("\(issue.createdBy?.name ?? "Someone") · \(issue.createdAt?.relative ?? "")").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                .swipeActions {
                    if issue.isOpen {
                        Button { app.perform("Issue resolved") { try await app.seerr(instance).resolveIssue(issue.id); await load() } } label: { Label("Resolve", systemImage: "checkmark") }.tint(Theme.ok)
                    }
                }
            }
        }
        .navigationTitle("Issues")
        .overlay { if loading && issues.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task(id: openOnly) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        issues = (try? await app.seerr(instance).issues(openOnly: openOnly, take: 50).results) ?? []
    }
}
