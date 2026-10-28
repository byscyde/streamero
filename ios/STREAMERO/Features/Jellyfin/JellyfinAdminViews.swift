import StreameroKit
import SwiftUI

struct JellyfinPluginsView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var plugins: [JellyfinPlugin] = []
    @State private var catalog: [JellyfinPackage] = []
    @State private var showCatalog = false
    @State private var removing: JellyfinPlugin?

    var body: some View {
        List {
            if plugins.contains(where: \.needsRestart) {
                Label("Restart Jellyfin to finish plugin changes.", systemImage: "arrow.clockwise.circle").foregroundStyle(Theme.warning)
            }
            ForEach(plugins) { plugin in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name).font(.subheadline.weight(.semibold))
                        Text([plugin.version, plugin.status].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { plugin.isActive }, set: { on in
                        app.perform(on ? "Enabled \(plugin.name)" : "Disabled \(plugin.name)") { try await app.jellyfin(instance).setPlugin(plugin, enabled: on); await load() }
                    }))
                    .labelsHidden()
                }
                .swipeActions {
                    if plugin.canUninstall != false {
                        Button(role: .destructive) { removing = plugin } label: { Label("Uninstall", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("Plugins")
        .toolbar { Button { showCatalog = true } label: { Image(systemName: "plus") }.accessibilityLabel("Catalog") }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showCatalog) {
            NavigationStack { JellyfinCatalogView(instance: instance, installed: Set(plugins.map(\.name))) }
        }
        .confirmationDialog("Uninstall \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                guard let plugin = removing else { return }
                app.perform("Uninstalled \(plugin.name); restart Jellyfin") { try await app.jellyfin(instance).uninstall(plugin); await load() }
            }
        }
    }

    private func load() async { plugins = ((try? await app.jellyfin(instance).plugins()) ?? plugins).sorted { $0.name < $1.name } }
}

struct JellyfinCatalogView: View {
    var instance: ServiceInstance
    var installed: Set<String>
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var packages: [JellyfinPackage] = []
    @State private var query = ""

    var body: some View {
        List {
            let grouped = Dictionary(grouping: packages.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { $0.category ?? "Other" }
            ForEach(grouped.keys.sorted(), id: \.self) { category in
                Section(category) {
                    ForEach(grouped[category] ?? []) { package in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(package.name).font(.subheadline.weight(.semibold))
                                if let text = package.overview ?? package.description { Text(text).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2) }
                            }
                            Spacer()
                            if installed.contains(package.name) {
                                Pill(text: "Installed", color: Theme.ok)
                            } else {
                                Button("Install") { app.perform("Installing \(package.name); restart Jellyfin afterwards") { try await app.jellyfin(instance).install(package) } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if packages.isEmpty { ProgressView() } }
        .searchable(text: $query)
        .navigationTitle("Plugin catalog")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task {
            do { packages = try await app.jellyfin(instance).catalog().sorted { $0.name < $1.name } } catch { app.show(AppState.describe(error), error: true) }
        }
    }
}

struct JellyfinDevicesView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var devices: [JellyfinDevice] = []

    var body: some View {
        List(devices) { device in
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name ?? "Device").font(.subheadline.weight(.semibold))
                Text([device.appName, device.appVersion, device.lastUserName, device.dateLastActivity?.relative].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .swipeActions {
                Button(role: .destructive) { app.perform("Device signed out") { try await app.jellyfin(instance).deleteDevice(device.id); await load() } } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
            }
        }
        .navigationTitle("Devices")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { devices = (try? await app.jellyfin(instance).devices()) ?? devices }
}

struct JellyfinApiKeysView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var keys: [JellyfinApiKey] = []
    @State private var creating = false
    @State private var appName = ""

    var body: some View {
        List(keys) { key in
            VStack(alignment: .leading, spacing: 2) {
                Text(key.appName ?? "App").font(.subheadline.weight(.semibold))
                Text(key.accessToken).font(.caption2.monospaced()).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                if let date = key.dateCreated { Text("Created \(date.relative)").font(.caption2).foregroundStyle(Theme.textSecondary) }
            }
            .swipeActions {
                if key.accessToken != instance.apiKey {
                    Button(role: .destructive) { app.perform("Key revoked") { try await app.jellyfin(instance).revokeApiKey(key.accessToken); await load() } } label: { Label("Revoke", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("API keys")
        .toolbar { Button { creating = true } label: { Image(systemName: "plus") } }
        .refreshable { await load() }
        .task { await load() }
        .alert("New API key", isPresented: $creating) {
            TextField("App name", text: $appName)
            Button("Create") {
                let name = appName
                appName = ""
                app.perform("Key created") { try await app.jellyfin(instance).createApiKey(app: name); await load() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async { keys = (try? await app.jellyfin(instance).apiKeys()) ?? keys }
}

struct JellyfinLogsView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var files: [JellyfinLogFile] = []

    var body: some View {
        List(files) { file in
            NavigationLink { JellyfinLogFileView(instance: instance, name: file.name) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.subheadline.monospaced())
                    Text([Format.bytes(file.size), file.dateModified?.relative].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .navigationTitle("Server logs")
        .task { files = ((try? await app.jellyfin(instance).logFiles()) ?? []).sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) } }
    }
}

struct JellyfinLogFileView: View {
    var instance: ServiceInstance
    var name: String
    @Environment(AppState.self) private var app
    @State private var text: String?

    var body: some View {
        ScrollView {
            if let text {
                // Newest lines are at the end; show the last part so the view stays fast.
                Text(String(text.suffix(200_000)))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                ProgressView().padding()
            }
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if let text { ShareLink(item: text) } }
        .task {
            do { text = try await app.jellyfin(instance).logFile(name) } catch { text = AppState.describe(error) }
        }
    }
}

/// Permissions, library access and limits for one user (Dashboard → Users → user in the web UI).
struct JellyfinPolicyView: View {
    var instance: ServiceInstance
    var user: JellyfinUser
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var policy: JellyfinPolicy?
    @State private var libraries: [VirtualFolder] = []

    var body: some View {
        Form {
            if let policy {
                Section("Permissions") {
                    ForEach(JellyfinPermission.allCases) { permission in
                        Toggle(permission.title, isOn: Binding(get: { policy.flag(permission) }, set: { self.policy?.set(permission, $0) }))
                    }
                }
                Section("Library access") {
                    Toggle("All libraries", isOn: Binding(get: { policy.allLibraries }, set: { self.policy?.allLibraries = $0 }))
                    if !policy.allLibraries {
                        ForEach(libraries.filter { $0.itemId != nil }) { library in
                            let id = library.itemId ?? ""
                            Toggle(library.name, isOn: Binding(get: { policy.enabledLibraries.contains(id) }, set: { on in
                                if on { self.policy?.enabledLibraries.insert(id) } else { self.policy?.enabledLibraries.remove(id) }
                            }))
                        }
                    }
                }
                Section {
                    Stepper("Max streams: \(policy.maxActiveSessions == 0 ? "unlimited" : String(policy.maxActiveSessions))",
                            value: Binding(get: { policy.maxActiveSessions }, set: { self.policy?.maxActiveSessions = max(0, $0) }), in: 0...20)
                    Picker("Remote bitrate", selection: Binding(get: { policy.remoteBitrateLimit }, set: { self.policy?.remoteBitrateLimit = $0 })) {
                        Text("Unlimited").tag(0)
                        ForEach([2, 4, 8, 10, 15, 20, 40], id: \.self) { mbps in Text("\(mbps) Mbps").tag(mbps * 1_000_000) }
                        if ![0, 2, 4, 8, 10, 15, 20, 40].map({ $0 * 1_000_000 }).contains(policy.remoteBitrateLimit) {
                            Text("\(policy.remoteBitrateLimit / 1_000_000) Mbps").tag(policy.remoteBitrateLimit)
                        }
                    }
                } header: {
                    Text("Limits")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(user.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let policy else { return }
                    app.perform("Saved \(user.name)") { try await app.jellyfin(instance).save(policy, userId: user.id); dismiss() }
                }
                .disabled(policy == nil)
            }
        }
        .task {
            do {
                let client = try app.jellyfin(instance)
                policy = try await client.policy(userId: user.id)
                libraries = (try? await client.libraries()) ?? []
            } catch {
                app.show(AppState.describe(error), error: true)
                dismiss()
            }
        }
    }
}

struct AddLibraryView: View {
    var instance: ServiceInstance
    var onSave: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: JellyfinCollectionType = .movies
    @State private var path = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Picker("Content type", selection: $type) { ForEach(JellyfinCollectionType.allCases) { Text($0.title).tag($0) } }
                TextField("Folder on the server, e.g. /media/movies", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("The folder must exist on the machine running Jellyfin. Jellyfin starts scanning it right away.")
            }
        }
        .navigationTitle("New library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let (n, t, p) = (name, type, path)
                    app.perform("Library \(n) added") {
                        try await app.jellyfin(instance).addLibrary(name: n, type: t, paths: [p])
                        onSave()
                        dismiss()
                    }
                }
                .disabled(name.isEmpty || path.isEmpty)
            }
        }
    }
}
