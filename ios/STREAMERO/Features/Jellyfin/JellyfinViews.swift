import StreameroKit
import SwiftUI

struct JellyfinHomeView: View {
    var body: some View {
        InstanceScope(kind: .jellyfin) { JellyfinHome(instance: $0) }
            .navigationTitle("Jellyfin")
    }
}

struct JellyfinHome: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var info: JellyfinSystemInfo?
    @State private var counts: ItemCounts?
    @State private var streams = 0
    @State private var error: String?
    @State private var confirm: PowerAction?

    enum PowerAction: String, Identifiable { case restart = "Restart", shutdown = "Shut down"; var id: String { rawValue } }

    var body: some View {
        List {
            Section {
                if let info {
                    LabeledContent("Server", value: info.serverName ?? "Jellyfin")
                    LabeledContent("Version", value: info.version ?? "—")
                    if let os = info.operatingSystemDisplayName { LabeledContent("System", value: os) }
                    if info.hasPendingRestart == true { Label("Restart pending", systemImage: "arrow.clockwise.circle").foregroundStyle(Theme.warning) }
                    if info.hasUpdateAvailable == true { Label("Update available", systemImage: "arrow.down.app").foregroundStyle(Theme.warning) }
                } else if let error {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(Theme.error)
                } else {
                    ProgressView()
                }
            }
            if let counts {
                Section("Library") {
                    LabeledContent("Movies", value: "\(counts.movieCount ?? 0)")
                    LabeledContent("Series", value: "\(counts.seriesCount ?? 0)")
                    LabeledContent("Episodes", value: "\(counts.episodeCount ?? 0)")
                    LabeledContent("Albums", value: "\(counts.albumCount ?? 0)")
                    LabeledContent("Songs", value: "\(counts.songCount ?? 0)")
                }
            }
            Section("Manage") {
                NavigationLink { JellyfinSessionsList(instance: instance) } label: { Label("Active streams", systemImage: "play.circle").badge(streams) }
                NavigationLink { JellyfinLibrariesView(instance: instance) } label: { Label("Libraries & scans", systemImage: "books.vertical") }
                NavigationLink { JellyfinLatestView(instance: instance) } label: { Label("Recently added", systemImage: "sparkles") }
                NavigationLink { JellyfinUsersView(instance: instance) } label: { Label("Users", systemImage: "person.2") }
                NavigationLink { JellyfinTasksView(instance: instance) } label: { Label("Scheduled tasks", systemImage: "clock.arrow.2.circlepath") }
                NavigationLink { JellyfinActivityView(instance: instance) } label: { Label("Activity log", systemImage: "list.bullet.rectangle") }
                NavigationLink { JellyfinPluginsView(instance: instance) } label: { Label("Plugins", systemImage: "puzzlepiece.extension") }
                NavigationLink { JellyfinDevicesView(instance: instance) } label: { Label("Devices", systemImage: "iphone.and.arrow.forward") }
                NavigationLink { JellyfinApiKeysView(instance: instance) } label: { Label("API keys", systemImage: "key") }
                NavigationLink { JellyfinLogsView(instance: instance) } label: { Label("Server logs", systemImage: "doc.plaintext") }
            }
            Section {
                Button { confirm = .restart } label: { Label("Restart server", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { confirm = .shutdown } label: { Label("Shut down server", systemImage: "power") }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("\(confirm?.rawValue ?? "") Jellyfin?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm?.rawValue ?? "", role: .destructive) {
                let action = confirm
                app.perform(action == .restart ? "Restarting Jellyfin" : "Shutting down Jellyfin") {
                    let client = try app.jellyfin(instance)
                    if action == .restart { try await client.restart() } else { try await client.shutdown() }
                }
            }
        } message: {
            Text("Everyone watching will be interrupted.")
        }
    }

    private func load() async {
        do {
            let client = try app.jellyfin(instance)
            info = try await client.systemInfo()
            counts = try? await client.itemCounts()
            streams = ((try? await client.sessions(activeWithinSeconds: 120)) ?? []).filter(\.isPlaying).count
            error = nil
        } catch { self.error = AppState.describe(error) }
    }
}

struct JellyfinSessionsView: View {
    var body: some View {
        InstanceScope(kind: .jellyfin) { JellyfinSessionsList(instance: $0) }
    }
}

struct JellyfinSessionsList: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var sessions: [JellyfinSession] = []
    @State private var messageTarget: JellyfinSession?
    @State private var messageText = ""
    @State private var loading = false

    var body: some View {
        List {
            let playing = sessions.filter(\.isPlaying)
            let idle = sessions.filter { !$0.isPlaying }
            if playing.isEmpty && !loading { ContentUnavailableView("Nobody is watching", systemImage: "play.slash") }
            if !playing.isEmpty {
                Section("Playing") {
                    ForEach(playing) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(session.nowPlayingItem?.displayTitle ?? "").font(.subheadline.weight(.semibold)).lineLimit(2)
                                Spacer()
                                if session.playState?.isPaused == true { Image(systemName: "pause.fill").foregroundStyle(Theme.textSecondary) }
                            }
                            Text([session.userName, session.deviceName, session.client, session.remoteEndPoint].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                            ProgressBar(value: session.progress)
                            HStack(spacing: 6) {
                                Text("\(Format.ticks(session.playState?.positionTicks)) / \(Format.ticks(session.nowPlayingItem?.runTimeTicks))").font(.caption2.monospacedDigit())
                                Spacer()
                                if let t = session.transcodingInfo, session.isTranscoding {
                                    Pill(text: ["Transcode", t.videoCodec?.uppercased(), t.bitrate.map { "\($0 / 1_000_000) Mbps" }].compactMap { $0 }.joined(separator: " "), color: Theme.warning)
                                } else {
                                    Pill(text: session.playState?.playMethod ?? "Direct", color: Theme.ok)
                                }
                            }
                            if let reasons = session.transcodingInfo?.transcodeReasons, !reasons.isEmpty {
                                Text(reasons.joined(separator: ", ")).font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { command(.stop, session) } label: { Label("Stop", systemImage: "stop.fill") }
                            Button { command(session.playState?.isPaused == true ? .unpause : .pause, session) } label: {
                                Label(session.playState?.isPaused == true ? "Resume" : "Pause", systemImage: session.playState?.isPaused == true ? "play.fill" : "pause.fill")
                            }
                            .tint(Theme.accent)
                            Button { messageTarget = session } label: { Label("Message", systemImage: "text.bubble") }.tint(.blue)
                        }
                    }
                }
            }
            if !idle.isEmpty {
                Section("Connected devices") {
                    ForEach(idle) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text([session.userName, session.deviceName].compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
                            Text([session.client, session.applicationVersion, session.lastActivityDate?.relative].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Streams")
        .overlay { if loading && sessions.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert("Send a message", isPresented: Binding(get: { messageTarget != nil }, set: { if !$0 { messageTarget = nil } })) {
            TextField("Message", text: $messageText)
            Button("Send") {
                guard let target = messageTarget else { return }
                let text = messageText
                messageText = ""
                app.perform("Message sent") { try await app.jellyfin(instance).message(sessionId: target.id, header: "Streamero", text: text) }
            }
            Button("Cancel", role: .cancel) { messageText = "" }
        } message: {
            Text("Shown on \(messageTarget?.deviceName ?? "the device").")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        sessions = (try? await app.jellyfin(instance).sessions()) ?? sessions
    }

    private func command(_ command: JellyfinPlaystateCommand, _ session: JellyfinSession) {
        app.perform(nil) {
            try await app.jellyfin(instance).send(command, to: session.id)
            try? await Task.sleep(for: .milliseconds(600))
            await load()
        }
    }
}

struct JellyfinLibrariesView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var libraries: [VirtualFolder] = []
    @State private var adding = false
    @State private var removing: VirtualFolder?
    @State private var pathTarget: VirtualFolder?
    @State private var newPath = ""

    var body: some View {
        List {
            Section {
                Button { app.perform("Scanning all libraries") { try await app.jellyfin(instance).scanAllLibraries() } } label: {
                    Label("Scan all libraries", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Section("Libraries") {
                ForEach(libraries) { library in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(library.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Pill(text: (library.collectionType ?? "mixed").capitalized)
                        }
                        ForEach(library.locations ?? [], id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary) }
                    }
                    .contextMenu {
                        Button { pathTarget = library } label: { Label("Add folder", systemImage: "folder.badge.plus") }
                        ForEach(library.locations ?? [], id: \.self) { location in
                            Button(role: .destructive) { app.perform("Folder removed") { try await app.jellyfin(instance).removePath(location, fromLibrary: library.name); await load() } } label: {
                                Label("Remove \(location)", systemImage: "folder.badge.minus")
                            }
                        }
                        Button(role: .destructive) { removing = library } label: { Label("Remove library", systemImage: "trash") }
                    }
                    .swipeActions {
                        if let id = library.itemId {
                            Button { app.perform("Refreshing \(library.name)") { try await app.jellyfin(instance).refresh(itemId: id) } } label: { Label("Scan", systemImage: "arrow.clockwise") }
                                .tint(Theme.accent)
                            Button { app.perform("Replacing metadata in \(library.name)") { try await app.jellyfin(instance).refresh(itemId: id, replaceAllMetadata: true) } } label: { Label("Replace metadata", systemImage: "wand.and.stars") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Libraries")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("New library") }
        .sheet(isPresented: $adding) {
            NavigationStack { AddLibraryView(instance: instance) { Task { await load() } } }
        }
        .alert("Add folder to \(pathTarget?.name ?? "")", isPresented: Binding(get: { pathTarget != nil }, set: { if !$0 { pathTarget = nil } })) {
            TextField("/media/…", text: $newPath).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add") {
                guard let library = pathTarget else { return }
                let path = newPath
                newPath = ""
                app.perform("Folder added") { try await app.jellyfin(instance).addPath(path, toLibrary: library.name); await load() }
            }
            Button("Cancel", role: .cancel) { newPath = "" }
        }
        .confirmationDialog("Remove library \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove library", role: .destructive) {
                guard let library = removing else { return }
                app.perform("Library removed") { try await app.jellyfin(instance).removeLibrary(name: library.name); await load() }
            }
        } message: {
            Text("Jellyfin forgets the library and its watch data. Files on disk are not deleted.")
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { libraries = (try? await app.jellyfin(instance).libraries()) ?? [] }
}

struct JellyfinLatestView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var items: [JellyfinItem] = []

    var body: some View {
        List(items) { item in
            HStack(spacing: 12) {
                Poster(url: item.hasPrimaryImage ? (try? app.jellyfin(instance))?.imageURL(itemId: item.id) : nil, width: 40, symbol: item.type == "MusicAlbum" ? "music.note" : "film")
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text([item.type, item.dateCreated?.relative].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .navigationTitle("Recently added")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { items = (try? await app.jellyfin(instance).latestItems(limit: 40)) ?? [] }
}

struct JellyfinUsersView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var users: [JellyfinUser] = []
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newPassword = ""
    @State private var passwordTarget: JellyfinUser?
    @State private var passwordText = ""
    @State private var deleteTarget: JellyfinUser?
    @State private var policyTarget: JellyfinUser?

    var body: some View {
        List(users) { user in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(user.name).font(.subheadline.weight(.semibold))
                        if user.isAdmin { Pill(text: "Admin", color: Theme.accent) }
                        if user.isDisabled { Pill(text: "Disabled", color: Theme.error) }
                    }
                    Text(Format.isRealDate(user.lastActivityDate) ? "Active \(user.lastActivityDate!.relative)" : "Never active")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Menu {
                    Button { update(user) { try await $0.setDisabled(userId: user.id, !user.isDisabled) } } label: {
                        Label(user.isDisabled ? "Enable" : "Disable", systemImage: user.isDisabled ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                    }
                    Button { update(user) { try await $0.setAdministrator(userId: user.id, !user.isAdmin) } } label: {
                        Label(user.isAdmin ? "Remove admin" : "Make admin", systemImage: "shield")
                    }
                    Button { policyTarget = user } label: { Label("Permissions & libraries", systemImage: "checklist") }
                    Button { passwordTarget = user } label: { Label("Set password", systemImage: "key") }
                    Button(role: .destructive) { deleteTarget = user } label: { Label("Delete user", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityLabel("Actions for \(user.name)")
            }
        }
        .navigationTitle("Users")
        .sheet(item: $policyTarget, onDismiss: { Task { await load() } }) { user in
            NavigationStack { JellyfinPolicyView(instance: instance, user: user) }
        }
        .toolbar { Button { showCreate = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("New user") }
        .refreshable { await load() }
        .task { await load() }
        .alert("New Jellyfin user", isPresented: $showCreate) {
            TextField("Name", text: $newName).textInputAutocapitalization(.never)
            SecureField("Password", text: $newPassword)
            Button("Create") {
                let (name, password) = (newName, newPassword)
                newName = ""; newPassword = ""
                app.perform("Created \(name)") { try await app.jellyfin(instance).createUser(name: name, password: password); await load() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New password for \(passwordTarget?.name ?? "")", isPresented: Binding(get: { passwordTarget != nil }, set: { if !$0 { passwordTarget = nil } })) {
            SecureField("Password", text: $passwordText)
            Button("Save") {
                guard let user = passwordTarget else { return }
                let text = passwordText
                passwordText = ""
                app.perform("Password changed") { try await app.jellyfin(instance).setPassword(userId: user.id, newPassword: text) }
            }
            Button("Cancel", role: .cancel) { passwordText = "" }
        }
        .confirmationDialog("Delete \(deleteTarget?.name ?? "")?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete user", role: .destructive) {
                guard let user = deleteTarget else { return }
                app.perform("Deleted \(user.name)") { try await app.jellyfin(instance).deleteUser(user.id); await load() }
            }
        }
    }

    private func load() async { users = (try? await app.jellyfin(instance).users()) ?? users }

    private func update(_ user: JellyfinUser, _ action: @escaping (JellyfinClient) async throws -> Void) {
        app.perform("Updated \(user.name)") {
            try await action(try app.jellyfin(instance))
            await load()
        }
    }
}

struct JellyfinTasksView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var tasks: [ScheduledTask] = []

    var body: some View {
        List {
            ForEach(Dictionary(grouping: tasks, by: { $0.category ?? "Other" }).sorted { $0.key < $1.key }, id: \.key) { category, list in
                Section(category) {
                    ForEach(list) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(task.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                if task.isRunning {
                                    Button("Stop") { app.perform("Stopping \(task.name)") { try await app.jellyfin(instance).stop(taskId: task.id); await load() } }
                                        .buttonStyle(.bordered).controlSize(.small)
                                } else {
                                    Button("Run") { app.perform("Started \(task.name)") { try await app.jellyfin(instance).run(taskId: task.id); await load() } }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                }
                            }
                            if task.isRunning { ProgressBar(value: (task.currentProgressPercentage ?? 0) / 100) }
                            if let last = task.lastExecutionResult, let end = last.endTimeUtc, Format.isRealDate(end) {
                                Text("\(last.status ?? "Finished") \(end.relative)").font(.caption2).foregroundStyle(last.status == "Failed" ? Theme.error : Theme.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Scheduled tasks")
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(tasks.contains(where: \.isRunning) ? 3 : 15))
            }
        }
    }

    private func load() async { tasks = (try? await app.jellyfin(instance).scheduledTasks()) ?? tasks }
}

struct JellyfinActivityView: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var entries: [ActivityEntry] = []

    var body: some View {
        List(entries) { entry in
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Text(entry.name ?? "").font(.subheadline).lineLimit(3)
                    Spacer()
                    if entry.severity == "Error" || entry.severity == "Warning" {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(entry.severity == "Error" ? Theme.error : Theme.warning)
                    }
                }
                if let overview = entry.shortOverview, !overview.isEmpty { Text(overview).font(.caption).foregroundStyle(Theme.textSecondary) }
                Text(entry.date?.relative ?? "").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Activity log")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { entries = (try? await app.jellyfin(instance).activityLog(limit: 100)) ?? [] }
}
