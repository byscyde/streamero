import PhotosUI
import StreameroCore
import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @State private var avatarItem: PhotosPickerItem?
    @State private var uploadingAvatar = false

    var body: some View {
        List {
            Section {
                HStack(spacing: Theme.Spacing.l) {
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        ZStack {
                            ArtworkView(url: avatarURL, size: 72, placeholderSymbol: "person.fill", circular: true)
                            if uploadingAvatar { ProgressView() }
                        }
                    }
                    .accessibilityLabel("Change profile picture")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.user?.displayName ?? "Listener").font(Theme.Typography.title)
                        Text(app.user?.email ?? "").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                        if app.user?.emailVerified == false {
                            Button("Verify your email") { Task { try? await app.api?.resendVerification(); app.show("Verification email sent", symbol: "envelope") } }
                                .font(Theme.Typography.caption.weight(.semibold))
                        }
                        if let role = app.user?.role, role != "user" { QualityBadge(text: role, lossless: true) }
                    }
                }
                .padding(.vertical, Theme.Spacing.s)
            }
            Section {
                NavigationLink(value: Route.settings) { Label("Settings", systemImage: "gearshape") }
                NavigationLink(value: Route.downloads) { Label("Downloads · \(Format.bytes(downloads.usedBytes))", systemImage: "arrow.down.circle") }
                NavigationLink(value: Route.recentlyPlayed) { Label("Listening history", systemImage: "clock") }
            }
            Section {
                LabeledContent("Server", value: app.serverURL?.host ?? "—")
                Button("Sign out", role: .destructive) { Task { await app.signOut() } }
            }
        }
        .streameroScreen()
        .navigationTitle("Profile")
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .task { await app.refreshUser() }
    }

    private var avatarURL: URL? {
        guard let path = app.user?.avatarUrl, let base = app.serverURL else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    private func upload(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
              let jpeg = image.preparingThumbnail(of: CGSize(width: 512, height: 512))?.jpegData(compressionQuality: 0.85),
              let api = app.api else { return }
        uploadingAvatar = true
        defer { uploadingAvatar = false }
        let boundary = "streamero-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        do {
            let _: User = try await api.send(Endpoint("PUT", "v1/me/avatar", body: body, contentType: "multipart/form-data; boundary=\(boundary)"))
            await app.refreshUser()
            Haptics.success()
        } catch { app.show((error as? LocalizedError)?.errorDescription ?? "Upload failed", symbol: "exclamationmark.triangle") }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @State private var displayName = ""
    @State private var allowExplicit = true
    @State private var historyEnabled = true
    @State private var personalization = true
    @State private var exportURL: URL?
    @State private var confirmDelete = false
    @State private var deletePassword = ""
    @State private var showPasswordChange = false
    @State private var sessions: [SessionInfo] = []
    @State private var cacheBytes = ImagePipeline.shared.diskUsage

    struct SessionInfo: Decodable, Identifiable { var id: String; var device: String?; var lastActiveAt: Date }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Account") {
                TextField("Display name", text: $displayName).onSubmit { patch(["displayName": .string(displayName)]) }
                if app.user?.hasPassword == true { Button("Change password") { showPasswordChange = true } }
            }

            Section {
                Picker("Wi-Fi streaming", selection: $settings.values.quality.wifi) { qualityOptions }
                Picker("Cellular streaming", selection: $settings.values.quality.cellular) { qualityOptions }
                Picker("Downloads", selection: $settings.values.quality.download) { qualityOptions }
            } header: { Text("Audio quality") } footer: {
                Text("Lossless is delivered as ALAC only when the original file is lossless; otherwise the best available AAC stream plays. Low Data Mode always uses Data Saver.")
            }

            Section("Playback") {
                Toggle("Gapless playback", isOn: $settings.values.gapless)
                VStack(alignment: .leading) {
                    Text(settings.values.crossfadeSeconds < 0.5 ? "Crossfade: off" : "Crossfade: \(Int(settings.values.crossfadeSeconds)) s")
                    Slider(value: $settings.values.crossfadeSeconds, in: 0...12, step: 1)
                }
                Toggle("Show lyrics when opening the player", isOn: $settings.values.showLyricsByDefault)
                Toggle("Autoplay next video", isOn: $settings.values.autoplayVideos)
            }

            Section("Subtitles") {
                Toggle("Show subtitles by default", isOn: $settings.values.subtitlesEnabled)
                LabeledContent("Preferred languages", value: settings.values.subtitleLanguages.prefix(3).joined(separator: ", "))
                VStack(alignment: .leading) {
                    Text("Text size \(settings.values.subtitleScale, specifier: "%.2g")×")
                    Slider(value: $settings.values.subtitleScale, in: 0.75...2, step: 0.25)
                }
                Toggle("Background behind text", isOn: $settings.values.subtitleBackground)
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.values.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Allow explicit content", isOn: $allowExplicit).onChange(of: allowExplicit) { _, v in patch(["allowExplicit": .bool(v)]) }
                Toggle("Save listening history", isOn: $historyEnabled).onChange(of: historyEnabled) { _, v in patch(["historyEnabled": .bool(v)]) }
                Toggle("Personalised recommendations", isOn: $personalization).onChange(of: personalization) { _, v in patch(["personalizationEnabled": .bool(v)]) }
                Button("Clear listening history", role: .destructive) {
                    Task { try? await app.api?.sendEmpty(Endpoint("DELETE", "v1/me/history")); app.show("History cleared", symbol: "trash") }
                }
            } header: { Text("Privacy") } footer: {
                Text("Recommendations are explainable and rule-based (genres, artists, favourites and listening history on this server). Turning history off stops storing what you play.")
            }

            Section("Storage") {
                LabeledContent("Downloads", value: Format.bytes(downloads.usedBytes))
                LabeledContent("Artwork cache", value: Format.bytes(Int64(cacheBytes)))
                Button("Clear artwork cache") { ImagePipeline.shared.clear(); cacheBytes = 0 }
            }

            if !sessions.isEmpty {
                Section("Signed-in devices") {
                    ForEach(sessions) { s in
                        LabeledContent(s.device ?? "Unknown device", value: s.lastActiveAt.formatted(.relative(presentation: .named)))
                            .swipeActions { Button("Sign out", role: .destructive) { revoke(s) } }
                    }
                    Button("Sign out everywhere", role: .destructive) {
                        Task { try? await app.api?.sendEmpty(Endpoint("POST", "v1/auth/logout-all")); await app.signOut() }
                    }
                }
            }

            Section("Your data") {
                Button("Export my data") { Task { await exportData() } }
                if let exportURL { ShareLink(item: exportURL) { Label("Share export", systemImage: "square.and.arrow.up") } }
                Button("Delete account", role: .destructive) { confirmDelete = true }
            }

            Section("Server") {
                LabeledContent("Address", value: app.serverURL?.absoluteString ?? "—")
                Button("Connect to a different server") { app.changeServer() }
            }

            Section {
                LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
            }
        }
        .streameroScreen()
        .navigationTitle("Settings")
        .onAppear {
            displayName = app.user?.displayName ?? ""
            allowExplicit = app.user?.allowExplicit ?? true
            historyEnabled = app.user?.historyEnabled ?? true
            personalization = app.user?.personalizationEnabled ?? true
        }
        .task { await loadSessions() }
        .sheet(isPresented: $showPasswordChange) { ChangePasswordSheet() }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            if app.user?.hasPassword == true { SecureField("Password", text: $deletePassword) }
            Button("Delete permanently", role: .destructive) {
                Task {
                    do {
                        try await app.api?.deleteAccount(password: deletePassword.isEmpty ? nil : deletePassword)
                        downloads.deleteAll()
                        await app.signOut()
                    } catch { app.show((error as? LocalizedError)?.errorDescription ?? "Could not delete account", symbol: "exclamationmark.triangle") }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your playlists, library and history are removed from the server. This can't be undone.") }
    }

    @ViewBuilder private var qualityOptions: some View {
        ForEach(StreamProfile.allCases) { p in Text(p.title).tag(p) }
    }

    private func patch(_ fields: [String: JSONValue]) {
        Task {
            do { _ = try await app.api?.updateProfile(fields); await app.refreshUser() } catch { app.show("Could not save", symbol: "exclamationmark.triangle") }
        }
    }

    private func exportData() async {
        guard let data = try? await app.api?.exportData() else { app.show("Export failed", symbol: "exclamationmark.triangle"); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("streamero-export.json")
        try? data.write(to: url)
        exportURL = url
    }

    private func loadSessions() async {
        struct R: Decodable { var items: [SessionInfo] }
        if let r: R = try? await app.api?.send(Endpoint("GET", "v1/me/sessions")) { sessions = r.items }
    }

    private func revoke(_ s: SessionInfo) {
        Task {
            try? await app.api?.sendEmpty(Endpoint("DELETE", "v1/me/sessions/\(s.id)"))
            await loadSessions()
        }
    }
}

struct ChangePasswordSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var next = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                SecureField("Current password", text: $current).textContentType(.password)
                SecureField("New password", text: $next).textContentType(.newPassword)
                if let error { Text(error).foregroundStyle(Theme.Palette.danger) }
                Text("Changing your password signs you out on other devices.").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textTertiary)
            }
            .navigationTitle("Change password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            do {
                                try await app.api?.sendEmpty(.json("POST", "v1/auth/change-password", ["currentPassword": current, "newPassword": next]))
                                app.show("Password changed. Please sign in again.")
                                dismiss()
                                await app.signOut()
                            } catch { self.error = (error as? LocalizedError)?.errorDescription }
                        }
                    }
                    .disabled(next.count < 10 || current.isEmpty)
                }
            }
        }
    }
}
