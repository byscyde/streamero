import StreameroKit
import SwiftUI

/// Everything under Settings and System in the *arr web UIs, for one instance.
struct ArrManageView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var confirm: Power?

    enum Power: String, Identifiable { case restart = "Restart", shutdown = "Shut down"; var id: String { rawValue } }

    var body: some View {
        List {
            Section("Settings") {
                ForEach(ProviderResource.available(for: instance.kind)) { resource in
                    NavigationLink { ProviderListView(instance: instance, resource: resource) } label: { Label(resource.title, systemImage: resource.symbol) }
                }
                if instance.kind != .prowlarr {
                    NavigationLink { QualityProfilesView(instance: instance) } label: { Label("Quality profiles", systemImage: "slider.horizontal.3") }
                    NavigationLink { RootFoldersView(instance: instance) } label: { Label("Root folders", systemImage: "folder") }
                }
                NavigationLink { TagsView(instance: instance) } label: { Label("Tags", systemImage: "tag") }
            }
            Section("System") {
                NavigationLink { ArrStatusView(instance: instance) } label: { Label("Status & health", systemImage: "stethoscope") }
                NavigationLink { ArrTasksView(instance: instance) } label: { Label("Tasks", systemImage: "clock.arrow.2.circlepath") }
                NavigationLink { ArrBackupsView(instance: instance) } label: { Label("Backups", systemImage: "externaldrive.badge.timemachine") }
                NavigationLink { ArrUpdatesView(instance: instance) } label: { Label("Updates", systemImage: "arrow.down.app") }
                NavigationLink { ArrLogsView(instance: instance) } label: { Label("Logs", systemImage: "doc.plaintext") }
                if instance.kind != .prowlarr {
                    NavigationLink { BlocklistView(instance: instance) } label: { Label("Blocklist", systemImage: "hand.raised") }
                }
            }
            Section {
                Button { app.perform("RSS sync started") { try await app.arr(instance).command(instance.kind == .prowlarr ? "ApplicationIndexerSync" : "RssSync") } } label: {
                    Label(instance.kind == .prowlarr ? "Sync indexers to apps" : "RSS sync now", systemImage: "dot.radiowaves.left.and.right")
                }
                Button { confirm = .restart } label: { Label("Restart \(instance.name)", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { confirm = .shutdown } label: { Label("Shut down \(instance.name)", systemImage: "power") }
            }
        }
        .navigationTitle(instance.name)
        .confirmationDialog("\(confirm?.rawValue ?? "") \(instance.name)?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm?.rawValue ?? "", role: .destructive) {
                let action = confirm
                app.perform(action == .restart ? "Restarting \(instance.name)" : "Shutting down \(instance.name)") {
                    if action == .restart { try await app.arr(instance).restartApp() } else { try await app.arr(instance).shutdownApp() }
                }
            }
        }
    }
}

// MARK: - Providers (download clients, indexers, lists, connections, apps…)

struct ProviderListView: View {
    var instance: ServiceInstance
    var resource: ProviderResource
    @Environment(AppState.self) private var app
    @State private var providers: [Provider] = []
    @State private var loading = false
    @State private var showSchemas = false
    @State private var deleting: Provider?

    var body: some View {
        List {
            if providers.isEmpty && !loading { ContentUnavailableView("No \(resource.title.lowercased())", systemImage: resource.symbol) }
            ForEach(providers) { provider in
                NavigationLink { ProviderEditorView(instance: instance, resource: resource, provider: provider, onSave: { Task { await load() } }) } label: {
                    HStack {
                        StatusDot(color: provider.isEnabled ? Theme.ok : Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).font(.subheadline.weight(.semibold))
                            Text(provider.implementationName).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { deleting = provider } label: { Label("Delete", systemImage: "trash") }
                    Button { test(provider) } label: { Label("Test", systemImage: "checkmark.shield") }.tint(Theme.accent)
                    if provider.enableKey != nil {
                        Button { toggle(provider) } label: { Label(provider.isEnabled ? "Disable" : "Enable", systemImage: "power") }
                    }
                }
            }
        }
        .navigationTitle(resource.title)
        .overlay { if loading && providers.isEmpty { ProgressView() } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { app.perform("All tests passed") { try await app.arr(instance).testAll(resource) } } label: { Image(systemName: "checkmark.shield") }
                    .accessibilityLabel("Test all")
                Button { showSchemas = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showSchemas) {
            NavigationStack { SchemaPickerView(instance: instance, resource: resource, onSave: { Task { await load() } }) }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let provider = deleting else { return }
                app.perform("Deleted \(provider.name)") { try await app.arr(instance).delete(provider, in: resource); await load() }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { providers = try await app.arr(instance).providers(resource).sorted { $0.name < $1.name } } catch { app.show(AppState.describe(error), error: true) }
    }

    private func test(_ provider: Provider) {
        app.perform("\(provider.name) works") { try await app.arr(instance).test(provider, in: resource) }
    }

    private func toggle(_ provider: Provider) {
        var updated = provider
        updated.isEnabled.toggle()
        app.perform(updated.isEnabled ? "Enabled" : "Disabled") { try await app.arr(instance).save(updated, in: resource); await load() }
    }
}

struct SchemaPickerView: View {
    var instance: ServiceInstance
    var resource: ProviderResource
    var onSave: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var schemas: [Provider] = []
    @State private var query = ""

    var body: some View {
        List {
            ForEach(schemas.filter { query.isEmpty || $0.implementationName.localizedCaseInsensitiveContains(query) }, id: \.implementation) { schema in
                NavigationLink {
                    ProviderEditorView(instance: instance, resource: resource, provider: schema, onSave: { onSave(); dismiss() })
                } label: {
                    Text(schema.implementationName)
                }
            }
        }
        .overlay { if schemas.isEmpty { ProgressView() } }
        .searchable(text: $query)
        .navigationTitle("Add \(resource.title.lowercased())")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task {
            do { schemas = try await app.arr(instance).providerSchemas(resource).sorted { $0.implementationName < $1.implementationName } } catch { app.show(AppState.describe(error), error: true) }
        }
    }
}

/// Generic editor for a provider's fields, the same form the web UI builds from the schema.
struct ProviderEditorView: View {
    var instance: ServiceInstance
    var resource: ProviderResource
    @State var provider: Provider
    var onSave: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: Binding(get: { provider.name }, set: { provider.name = $0 }))
                if provider.enableKey != nil {
                    Toggle("Enabled", isOn: Binding(get: { provider.isEnabled }, set: { provider.isEnabled = $0 }))
                }
                if let link = provider.infoLink { Link("Documentation", destination: link).font(.footnote) }
            } header: {
                Text(provider.implementationName)
            }
            let fields = provider.fields.filter { !$0.hidden && (showAdvanced || !$0.advanced) }
            if !fields.isEmpty {
                Section("Settings") {
                    ForEach(fields) { field in FieldEditor(field: field) { provider.setField(field.name, $0) } }
                }
            }
            if !provider.toggles.isEmpty {
                Section("Options") {
                    ForEach(provider.toggles.map { $0.key }, id: \.self) { key in
                        Toggle(Self.humanise(key), isOn: Binding(get: { provider.raw[key]?.boolValue ?? false }, set: { provider.setToggle(key, $0) }))
                    }
                }
            }
            Section {
                Toggle("Show advanced settings", isOn: $showAdvanced)
                Button { run("\(provider.name) works") { try await app.arr(instance).test(provider, in: resource) } } label: { Label("Test", systemImage: "checkmark.shield") }
                    .disabled(busy)
            }
        }
        .navigationTitle(provider.isNew ? "New" : provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { save() } label: { if busy { ProgressView() } else { Text("Save") } }.disabled(busy || provider.name.isEmpty)
            }
        }
    }

    private func save() {
        run("Saved \(provider.name)") {
            try await app.arr(instance).save(provider, in: resource)
            onSave()
            dismiss()
        }
    }

    private func run(_ message: String, _ action: @escaping () async throws -> Void) {
        busy = true
        app.perform(message) {
            defer { busy = false }
            try await action()
        }
    }

    /// "onGrab" → "On grab", "removeCompletedDownloads" → "Remove completed downloads"
    static func humanise(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for ch in key {
            if ch.isUppercase, !current.isEmpty { words.append(current); current = "" }
            current.append(ch)
        }
        words.append(current)
        let sentence = words.map { $0.lowercased() }.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}

/// One field of a provider form.
struct FieldEditor: View {
    var field: ProviderField
    var onChange: (JSONValue) -> Void
    @State private var text = ""
    @State private var flag = false
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.kind {
            case .text, .secret, .number, .list:
                LabeledContent(field.label) {
                    Group {
                        if field.kind == .secret {
                            SecureField(field.label, text: $text)
                        } else {
                            TextField(field.kind == .list ? "comma separated" : field.label, text: $text)
                                .keyboardType(field.kind == .number ? .numbersAndPunctuation : .default)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: text) { _, new in onChange(Self.value(for: field, text: new)) }
                }
            case .multiline:
                Text(field.label).font(.subheadline)
                TextEditor(text: $text).frame(minHeight: 80).font(.footnote.monospaced())
                    .onChange(of: text) { _, new in onChange(.string(new)) }
            case .toggle:
                Toggle(field.label, isOn: $flag).onChange(of: flag) { _, new in onChange(.bool(new)) }
            case .select:
                Picker(field.label, selection: $text) {
                    ForEach(field.options) { option in Text(option.name).tag(Self.key(option.value)) }
                }
                .onChange(of: text) { _, new in
                    if let option = field.options.first(where: { Self.key($0.value) == new }) { onChange(option.value) }
                }
            case .multiSelect:
                Text(field.label).font(.subheadline)
                ForEach(field.options) { option in
                    let key = Self.key(option.value)
                    Button {
                        if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
                        onChange(.array(field.options.filter { selection.contains(Self.key($0.value)) }.map(\.value)))
                    } label: {
                        HStack {
                            Text(option.name).foregroundStyle(.primary)
                            Spacer()
                            if selection.contains(key) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            case .readOnly:
                LabeledContent(field.label, value: field.displayValue)
            }
            if let help = field.helpText, !help.isEmpty {
                Text(help).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        switch field.value {
        case .string(let s): text = s
        case .number: text = field.kind == .select ? Self.key(field.value) : field.displayValue
        case .bool(let b): flag = b
        case .array(let items):
            if field.kind == .multiSelect { selection = Set(items.map(Self.key)) }
            else { text = items.compactMap { $0.stringValue ?? $0.intValue.map(String.init) }.joined(separator: ", ") }
        default: text = ""
        }
        if field.kind == .select, case .string(let s) = field.value { text = Self.key(.string(s)) }
    }

    static func key(_ value: JSONValue) -> String {
        switch value {
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        case .string(let s): s
        case .bool(let b): String(b)
        default: "\(value)"
        }
    }

    static func value(for field: ProviderField, text: String) -> JSONValue {
        switch field.kind {
        case .number: return Double(text.replacingOccurrences(of: ",", with: ".")).map(JSONValue.number) ?? .null
        case .list:
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Tag-type fields hold numbers (category ids) in some providers and strings in others.
            let numeric = (field.value.arrayValue ?? []).contains { if case .number = $0 { true } else { false } }
            return .array(parts.map { numeric ? (Double($0).map(JSONValue.number) ?? .string($0)) : .string($0) })
        default: return .string(text)
        }
    }
}

// MARK: - Profiles, folders, tags

struct QualityProfilesView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var profiles: [QualityProfileDetail] = []

    var body: some View {
        List(profiles) { profile in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(profile.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    Toggle("Upgrades", isOn: Binding(get: { profile.upgradeAllowed }, set: { allowed in
                        app.perform(allowed ? "Upgrades allowed" : "Upgrades off") { try await app.arr(instance).setUpgradeAllowed(profileId: profile.id, allowed); await load() }
                    }))
                    .labelsHidden()
                }
                if let cutoff = profile.cutoff { Text("Upgrade until \(cutoff)").font(.caption).foregroundStyle(Theme.textSecondary) }
                Text(profile.allowed.joined(separator: " · ")).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Quality profiles")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { profiles = (try? await app.arr(instance).qualityProfileDetails()) ?? profiles }
}

struct RootFoldersView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var folders: [RootFolder] = []
    @State private var adding = false
    @State private var newPath = ""

    var body: some View {
        List {
            ForEach(folders) { folder in
                LabeledContent(folder.path, value: "\(Format.bytes(folder.freeSpace)) free").font(.subheadline)
                    .swipeActions {
                        Button(role: .destructive) { app.perform("Removed \(folder.path)") { try await app.arr(instance).deleteRootFolder(folder.id); await load() } } label: { Label("Remove", systemImage: "trash") }
                    }
            }
        }
        .navigationTitle("Root folders")
        .toolbar { if instance.kind != .lidarr { Button { adding = true } label: { Image(systemName: "plus") } } }
        .refreshable { await load() }
        .task { await load() }
        .alert("Add root folder", isPresented: $adding) {
            TextField("/media/movies", text: $newPath).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add") {
                let path = newPath
                newPath = ""
                app.perform("Added \(path)") { try await app.arr(instance).addRootFolder(path); await load() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A folder that exists on the server running \(instance.name).") }
    }

    private func load() async { folders = (try? await app.arr(instance).rootFolders()) ?? folders }
}

struct TagsView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var tags: [ArrTag] = []
    @State private var adding = false
    @State private var label = ""

    var body: some View {
        List {
            ForEach(tags) { tag in
                Label(tag.label, systemImage: "tag")
                    .swipeActions {
                        Button(role: .destructive) { app.perform("Deleted tag") { try await app.arr(instance).deleteTag(tag.id); await load() } } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
        .overlay { if tags.isEmpty { ContentUnavailableView("No tags", systemImage: "tag") } }
        .navigationTitle("Tags")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .refreshable { await load() }
        .task { await load() }
        .alert("New tag", isPresented: $adding) {
            TextField("Label", text: $label).textInputAutocapitalization(.never)
            Button("Create") {
                let text = label
                label = ""
                app.perform("Created tag") { try await app.arr(instance).createTag(text); await load() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async { tags = (try? await app.arr(instance).tags()) ?? tags }
}

// MARK: - System

struct ArrStatusView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var status: ArrSystemStatus?
    @State private var health: [ArrHealth] = []
    @State private var disks: [DiskSpace] = []

    var body: some View {
        List {
            if let status {
                Section("About") {
                    LabeledContent("Version", value: status.version ?? "—")
                    if let os = status.osName { LabeledContent("OS", value: os) }
                    if status.isDocker == true { LabeledContent("Runs in", value: "Docker") }
                    if let start = status.startTime, Format.isRealDate(start) { LabeledContent("Up since", value: start.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
            Section("Health") {
                if health.isEmpty { Label("No issues", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                ForEach(health) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(item.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.color(item.severity))
                        if let wiki = item.wikiUrl, let url = URL(string: wiki) { Link("How to fix", destination: url).font(.caption) }
                    }
                }
            }
            if !disks.isEmpty {
                Section("Disk space") {
                    ForEach(disks, id: \.self) { disk in
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(disk.path ?? disk.label ?? "Disk", value: "\(Format.bytes(disk.freeSpace)) free")
                            ProgressBar(value: disk.usedFraction, color: disk.usedFraction > 0.9 ? Theme.error : Theme.ok)
                        }
                    }
                }
            }
        }
        .navigationTitle("Status")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let arr = try? app.arr(instance) else { return }
        status = try? await arr.systemStatus()
        health = (try? await arr.health()) ?? []
        disks = (try? await arr.diskSpace()) ?? []
    }
}

struct ArrTasksView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var tasks: [ArrTask] = []

    var body: some View {
        List(tasks) { task in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name ?? task.taskName ?? "Task").font(.subheadline.weight(.semibold))
                    Text(Self.subtitle(task)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Run") { app.perform("Started \(task.name ?? "task")") { try await app.arr(instance).run(task); await load() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .navigationTitle("Tasks")
        .refreshable { await load() }
        .task { await load() }
    }

    static func subtitle(_ task: ArrTask) -> String {
        var parts: [String] = []
        if let minutes = task.interval { parts.append("every \(interval(minutes))") }
        if let last = task.lastExecution, Format.isRealDate(last) { parts.append("last \(last.relative)") }
        if let next = task.nextExecution { parts.append("next \(next.relative)") }
        return parts.joined(separator: " · ")
    }

    static func interval(_ minutes: Int) -> String { minutes >= 1440 ? "\(minutes / 1440)d" : minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m" }

    private func load() async { tasks = (try? await app.arr(instance).tasks()) ?? tasks }
}

struct ArrBackupsView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var backups: [ArrBackup] = []

    var body: some View {
        List {
            Section {
                Button { app.perform("Backup started") { try await app.arr(instance).createBackup(); try? await Task.sleep(for: .seconds(3)); await load() } } label: {
                    Label("Back up now", systemImage: "externaldrive.badge.plus")
                }
            }
            Section("Backups") {
                ForEach(backups) { backup in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.name ?? "Backup").font(.subheadline.monospaced())
                        Text([backup.type?.capitalized, Format.bytes(backup.size), backup.time?.relative].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { app.perform("Backup deleted") { try await app.arr(instance).deleteBackup(backup.id); await load() } } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("Backups")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { backups = (try? await app.arr(instance).backups()) ?? backups }
}

struct ArrUpdatesView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var updates: [ArrUpdate] = []
    @State private var loaded = false

    var body: some View {
        List {
            if let latest = updates.first, latest.installable == true, latest.installed != true {
                Section {
                    Button { app.perform("Installing \(latest.version)") { try await app.arr(instance).installUpdate() } } label: {
                        Label("Install \(latest.version)", systemImage: "arrow.down.app.fill")
                    }
                } footer: {
                    Text("Only works when \(instance.name) is set to update itself (not with Docker images, which you update by pulling a new image).")
                }
            }
            ForEach(updates.prefix(10)) { update in
                Section {
                    ForEach(update.changes?.new ?? [], id: \.self) { Label($0, systemImage: "plus.circle").font(.caption) }
                    ForEach(update.changes?.fixed ?? [], id: \.self) { Label($0, systemImage: "wrench").font(.caption) }
                } header: {
                    HStack {
                        Text(update.version)
                        if update.installed == true { Pill(text: "Installed", color: Theme.ok) }
                        Spacer()
                        if let date = update.releaseDate { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                    }
                }
            }
        }
        .overlay { if !loaded { ProgressView() } else if updates.isEmpty { ContentUnavailableView("No update information", systemImage: "arrow.down.app") } }
        .navigationTitle("Updates")
        .task {
            updates = (try? await app.arr(instance).updates()) ?? []
            loaded = true
        }
    }
}

struct ArrLogsView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var entries: [ArrLogEntry] = []
    @State private var level = "info"

    var body: some View {
        List {
            Picker("Level", selection: $level) {
                Text("Info").tag("info"); Text("Warn").tag("warn"); Text("Error").tag("error")
            }
            .pickerStyle(.segmented)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.level?.uppercased() ?? "").font(.caption2.weight(.bold)).foregroundStyle(color(entry.level))
                        Text(entry.logger ?? "").font(.caption2).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(entry.time?.formatted(date: .omitted, time: .standard) ?? "").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                    Text(entry.message ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    if let exception = entry.exception { Text(exception).font(.caption2.monospaced()).foregroundStyle(Theme.error).lineLimit(6).textSelection(.enabled) }
                }
            }
        }
        .navigationTitle("Logs")
        .refreshable { await load() }
        .task(id: level) { await load() }
    }

    private func color(_ level: String?) -> Color {
        switch level?.lowercased() {
        case "error", "fatal": Theme.error
        case "warn": Theme.warning
        default: Theme.textSecondary
        }
    }

    private func load() async { entries = (try? await app.arr(instance).logs(level: level).records) ?? [] }
}

struct BlocklistView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var items: [BlocklistItem] = []

    var body: some View {
        List(items) { item in
            VStack(alignment: .leading, spacing: 3) {
                Text(item.sourceTitle ?? "Release").font(.subheadline).lineLimit(2)
                Text([item.indexer, item.quality?.name, item.date?.relative].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary)
                if let message = item.message { Text(message).font(.caption2).foregroundStyle(Theme.warning) }
            }
            .swipeActions {
                Button(role: .destructive) { app.perform("Removed from blocklist") { try await app.arr(instance).removeFromBlocklist(item.id); await load() } } label: { Label("Remove", systemImage: "trash") }
            }
        }
        .overlay { if items.isEmpty { ContentUnavailableView("Blocklist is empty", systemImage: "hand.raised") } }
        .navigationTitle("Blocklist")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { items = (try? await app.arr(instance).blocklist().records) ?? [] }
}
