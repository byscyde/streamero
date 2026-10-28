import StreameroKit
import SwiftUI

struct QBittorrentView: View {
    var body: some View {
        InstanceScope(kind: .qbittorrent) { instance in TorrentsList(instance: instance) }
            .navigationTitle("qBittorrent")
    }
}

struct TorrentsList: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var torrents: [Torrent] = []
    @State private var transfer: TransferInfo?
    @State private var altSpeed = false
    @State private var filter: TorrentFilter = .all
    @State private var error: String?
    @State private var adding = false
    @State private var magnet = ""
    @State private var category = ""
    @State private var deleting: Torrent?

    var body: some View {
        List {
            Section {
                HStack {
                    Label("\(Format.bytes(transfer?.dlInfoSpeed))/s", systemImage: "arrow.down").foregroundStyle(Theme.ok)
                    Spacer()
                    Label("\(Format.bytes(transfer?.upInfoSpeed))/s", systemImage: "arrow.up").foregroundStyle(Theme.accent)
                }
                .font(.subheadline.monospacedDigit().weight(.semibold))
                Toggle(isOn: Binding(get: { altSpeed }, set: { _ in toggleAltSpeed() })) {
                    Label("Alternative speed limits", systemImage: "tortoise")
                }
                Picker("Show", selection: $filter) { ForEach(TorrentFilter.allCases) { Text($0.title).tag($0) } }
            }
            if let error, torrents.isEmpty {
                ErrorStateView(message: error) { Task { await load() } }
            }
            Section("\(torrents.count) torrents") {
                ForEach(torrents) { torrent in
                    TorrentRow(torrent: torrent)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = torrent } label: { Label("Delete", systemImage: "trash") }
                            Button { act(torrent.isPaused ? "Resumed" : "Paused") { client in if torrent.isPaused { try await client.resume([torrent.hash]) } else { try await client.pause([torrent.hash]) } } } label: {
                                Label(torrent.isPaused ? "Resume" : "Pause", systemImage: torrent.isPaused ? "play" : "pause")
                            }
                            .tint(Theme.accent)
                        }
                        .contextMenu {
                            Button { act("Rechecking") { try await $0.recheck([torrent.hash]) } } label: { Label("Force recheck", systemImage: "checkmark.arrow.trianglehead.counterclockwise") }
                            Button { act("Reannounced") { try await $0.reannounce([torrent.hash]) } } label: { Label("Reannounce", systemImage: "dot.radiowaves.up.forward") }
                        }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { act("All resumed") { try await $0.resume(["all"]) } } label: { Label("Resume all", systemImage: "play") }
                    Button { act("All paused") { try await $0.pause(["all"]) } } label: { Label("Pause all", systemImage: "pause") }
                } label: { Image(systemName: "playpause") }
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add torrent")
            }
        }
        .refreshable { await load() }
        .task(id: filter) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert("Add torrent", isPresented: $adding) {
            TextField("Magnet link or .torrent URL", text: $magnet).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Category (optional)", text: $category).textInputAutocapitalization(.never)
            Button("Add") {
                let urls = magnet, cat = category
                magnet = ""
                act("Torrent added") { try await $0.add(urls: urls, category: cat) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let torrent = deleting {
                Button("Remove torrent, keep files") { act("Removed") { try await $0.delete([torrent.hash], deleteFiles: false) } }
                Button("Remove torrent and files", role: .destructive) { act("Removed with files") { try await $0.delete([torrent.hash], deleteFiles: true) } }
            }
        }
    }

    private func load() async {
        do {
            let client = try app.qbittorrent(instance)
            torrents = try await client.torrents(filter: filter)
            transfer = try? await client.transferInfo()
            altSpeed = (try? await client.alternativeSpeedLimitsEnabled()) ?? altSpeed
            error = nil
        } catch {
            self.error = AppState.describe(error)
        }
    }

    private func toggleAltSpeed() {
        act(altSpeed ? "Normal speed" : "Alternative speed on") { try await $0.toggleAlternativeSpeedLimits() }
    }

    private func act(_ message: String, _ action: @escaping (QBittorrentClient) async throws -> Void) {
        app.perform(message) {
            try await action(try app.qbittorrent(instance))
            await load()
        }
    }
}

struct TorrentRow: View {
    var torrent: Torrent
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(torrent.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            ProgressBar(value: torrent.progress ?? 0, color: torrent.isErrored ? Theme.error : torrent.isComplete ? Theme.ok : Theme.accent)
            HStack(spacing: 8) {
                Text(torrent.stateTitle).foregroundStyle(torrent.isErrored ? Theme.error : Theme.textSecondary)
                Text(Format.percent(torrent.progress ?? 0))
                Text(Format.bytes(torrent.size))
                if let eta = torrent.etaText, !torrent.isComplete { Text(eta) }
                Spacer()
                if let down = torrent.dlspeed, down > 0 { Text("↓ \(Format.bytes(down))/s") }
                if let up = torrent.upspeed, up > 0 { Text("↑ \(Format.bytes(up))/s") }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            if let category = torrent.category, !category.isEmpty { Pill(text: category) }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SABnzbd

struct SabnzbdView: View {
    var body: some View {
        InstanceScope(kind: .sabnzbd) { instance in SabnzbdHome(instance: instance) }
            .navigationTitle("SABnzbd")
    }
}

struct SabnzbdHome: View {
    var instance: ServiceInstance
    @Environment(AppState.self) private var app
    @State private var queue: SabQueue?
    @State private var history: [SabHistory.Slot] = []
    @State private var error: String?
    @State private var adding = false
    @State private var nzbURL = ""
    @State private var showHistory = false

    var body: some View {
        List {
            if let queue {
                Section {
                    HStack {
                        Label(Self.speedText(queue), systemImage: queue.paused == true ? "pause.circle" : "arrow.down.circle")
                            .foregroundStyle(queue.paused == true ? Theme.warning : Theme.ok)
                        Spacer()
                        Text([queue.sizeleft, queue.timeleft].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(Theme.textSecondary)
                    }
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    Button {
                        let paused = queue.paused == true
                        act(paused ? "Resumed" : "Paused") { client in if paused { try await client.resumeAll() } else { try await client.pauseAll() } }
                    } label: {
                        Label(queue.paused == true ? "Resume downloads" : "Pause downloads", systemImage: queue.paused == true ? "play" : "pause")
                    }
                    Menu {
                        ForEach([100, 75, 50, 25, 10], id: \.self) { percent in
                            Button(percent == 100 ? "No limit" : "\(percent)%") { act("Speed limit set") { try await $0.setSpeedLimit(percent: percent) } }
                        }
                    } label: {
                        LabeledContent("Speed limit", value: queue.speedlimit.map { $0.isEmpty || $0 == "100" ? "None" : "\($0)%" } ?? "None")
                    }
                }
            }
            if let error, queue == nil {
                ErrorStateView(message: error) { Task { await load() } }
            }
            Picker("Show", selection: $showHistory) { Text("Queue").tag(false); Text("History").tag(true) }
                .pickerStyle(.segmented)
            if showHistory {
                ForEach(history) { slot in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(slot.name ?? "Download").font(.subheadline).lineLimit(2)
                        HStack {
                            Text(slot.status ?? "").foregroundStyle(slot.status == "Failed" ? Theme.error : Theme.textSecondary)
                            Text(Format.bytes(slot.bytes))
                            if let category = slot.category { Text(category) }
                        }
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                        if let fail = slot.failMessage, !fail.isEmpty { Text(fail).font(.caption2).foregroundStyle(Theme.error) }
                    }
                    .swipeActions {
                        Button(role: .destructive) { act("Removed from history") { try await $0.deleteHistory(slot.nzoId) } } label: { Label("Delete", systemImage: "trash") }
                        if slot.status == "Failed" {
                            Button { act("Retrying") { try await $0.retry(slot.nzoId) } } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(Theme.accent)
                        }
                    }
                }
            } else {
                ForEach(queue?.slots ?? []) { slot in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(slot.filename ?? "Download").font(.subheadline.weight(.semibold)).lineLimit(2)
                        ProgressBar(value: slot.progress)
                        HStack {
                            Text(slot.status ?? "")
                            Text("\(slot.percentage ?? "0")%")
                            if let left = slot.timeleft { Text(left) }
                            Spacer()
                            if let category = slot.cat { Text(category) }
                        }
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { act("Deleted") { try await $0.delete(slot.nzoId) } } label: { Label("Delete", systemImage: "trash") }
                        let paused = slot.status == "Paused"
                        Button { act(paused ? "Resumed" : "Paused") { client in if paused { try await client.resume(slot.nzoId) } else { try await client.pause(slot.nzoId) } } } label: {
                            Label(paused ? "Resume" : "Pause", systemImage: paused ? "play" : "pause")
                        }
                        .tint(Theme.accent)
                    }
                }
            }
        }
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add NZB") }
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert("Add NZB", isPresented: $adding) {
            TextField("NZB URL", text: $nzbURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add") {
                let url = nzbURL
                nzbURL = ""
                act("NZB added") { try await $0.addURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    static func speedText(_ queue: SabQueue) -> String {
        if queue.paused == true { return "Paused" }
        let kilobytes = Double(queue.kbpersec ?? "") ?? 0
        return "\(Format.bytes(kilobytes * 1024))/s"
    }

    private func load() async {
        do {
            let client = try app.sabnzbd(instance)
            queue = try await client.queue()
            history = (try? await client.history().slots) ?? history
            error = nil
        } catch {
            self.error = AppState.describe(error)
        }
    }

    private func act(_ message: String, _ action: @escaping (SabnzbdClient) async throws -> Void) {
        app.perform(message) {
            try await action(try app.sabnzbd(instance))
            await load()
        }
    }
}
