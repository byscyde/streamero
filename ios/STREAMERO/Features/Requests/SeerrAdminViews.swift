import StreameroKit
import SwiftUI

struct SeerrUsersView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var users: [SeerrManagedUser] = []
    @State private var deleting: SeerrManagedUser?
    @State private var importing = false

    var body: some View {
        List(users) { user in
            NavigationLink { SeerrUserView(instance: instance, user: user, onChange: { Task { await load() } }) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(user.name).font(.subheadline.weight(.semibold))
                        if user.permissionSet.contains(.admin) { Pill(text: "Admin", color: Theme.accent) }
                    }
                    Text([user.email, user.requestCount.map { "\($0) requests" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .swipeActions {
                if user.id != 1 {
                    Button(role: .destructive) { deleting = user } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Request users")
        .toolbar {
            if app.first(.jellyfin) != nil {
                Button { importing = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("Import Jellyfin users")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $importing, onDismiss: { Task { await load() } }) {
            NavigationStack { SeerrImportView(instance: instance, existing: Set(users.compactMap(\.jellyfinUsername))) }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete user", role: .destructive) {
                guard let user = deleting else { return }
                app.perform("Deleted \(user.name)") { try await app.seerr(instance).deleteUser(user.id); await load() }
            }
        } message: {
            Text("Their requests are removed from \(instance.name). The Jellyfin account is not touched.")
        }
    }

    private func load() async { users = (try? await app.seerr(instance).users()) ?? users }
}

struct SeerrUserView: View {
    var instance: ServiceInstance
    var user: SeerrManagedUser
    var onChange: () -> Void
    @Environment(AppState.self) private var app
    @State private var permissions: SeerrPermissions
    @State private var requests: [SeerrRequest] = []

    init(instance: ServiceInstance, user: SeerrManagedUser, onChange: @escaping () -> Void) {
        self.instance = instance
        self.user = user
        self.onChange = onChange
        _permissions = State(initialValue: user.permissionSet)
    }

    var body: some View {
        List {
            Section {
                ForEach(SeerrPermissions.editable.indices, id: \.self) { index in
                    let (permission, title) = SeerrPermissions.editable[index]
                    Toggle(title, isOn: Binding(get: { permissions.contains(permission) }, set: { on in
                        if on { permissions.insert(permission) } else { permissions.remove(permission) }
                    }))
                }
                Button("Save permissions") {
                    let value = permissions
                    app.perform("Permissions saved") { try await app.seerr(instance).setPermissions(userId: user.id, value); onChange() }
                }
                .disabled(permissions == user.permissionSet)
            } header: {
                Text("Permissions")
            }
            Section("Recent requests") {
                if requests.isEmpty { Text("No requests").foregroundStyle(Theme.textSecondary) }
                ForEach(requests) { request in RequestRow(instance: instance, request: request) }
            }
        }
        .navigationTitle(user.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { requests = (try? await app.seerr(instance).requests(byUser: user.id)) ?? [] }
    }
}

struct SeerrImportView: View {
    var instance: ServiceInstance
    var existing: Set<String>
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var jellyfinUsers: [JellyfinUser] = []
    @State private var selected: Set<String> = []

    var body: some View {
        List(jellyfinUsers.filter { !existing.contains($0.name) }) { user in
            Button {
                if selected.contains(user.id) { selected.remove(user.id) } else { selected.insert(user.id) }
            } label: {
                HStack {
                    Text(user.name).foregroundStyle(.primary)
                    Spacer()
                    if selected.contains(user.id) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                }
            }
        }
        .overlay { if jellyfinUsers.isEmpty { ProgressView() } }
        .navigationTitle("Import from Jellyfin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    let ids = Array(selected)
                    app.perform("Imported \(ids.count) users") { try await app.seerr(instance).importJellyfinUsers(ids: ids); dismiss() }
                }
                .disabled(selected.isEmpty)
            }
        }
        .task {
            guard let jellyfin = app.first(.jellyfin) else { return }
            jellyfinUsers = (try? await app.jellyfin(jellyfin).users()) ?? []
        }
    }
}

struct SeerrJobsView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var jobs: [SeerrJob] = []

    var body: some View {
        List(jobs) { job in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).font(.subheadline.weight(.semibold))
                    Text([job.interval, job.nextExecutionTime.map { "next \($0.relative)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if job.running == true {
                    Button("Cancel") { app.perform("Cancelled") { try await app.seerr(instance).cancel(job: job.id); await load() } }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Run") { app.perform("Started \(job.name)") { try await app.seerr(instance).run(job: job.id); await load() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .navigationTitle("Jobs")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { jobs = (try? await app.seerr(instance).jobs()) ?? jobs }
}
