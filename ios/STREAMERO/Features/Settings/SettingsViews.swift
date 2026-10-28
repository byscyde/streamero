import StreameroKit
import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    BrandMark(size: 64)
                    Text("Welcome to Streamero").font(.system(.title2, design: .monospaced).weight(.bold))
                    Text("One app to run your media server: Jellyfin, requests, Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, qBittorrent and SABnzbd. Add the API key of each service you use — the streamero.net addresses are already filled in.")
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 8)
            }
            Section("Services") {
                ForEach(app.services) { instance in
                    NavigationLink { ServiceEditorView(instance: instance) } label: { ServiceRow(instance: instance) }
                }
            }
            Section {
                Text("Keys are stored only on this iPhone, in the Keychain. Streamero talks directly to your servers; nothing goes through a third party.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Set up")
        .accessibilityIdentifier("welcomeScreen")
    }
}

struct ServiceRow: View {
    var instance: ServiceInstance
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Theme.icon(instance.kind))
                .frame(width: 34, height: 34)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name).font(.body.weight(.semibold))
                Text(instance.url).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            if !instance.enabled {
                Pill(text: "Off")
            } else if instance.apiKey.isEmpty {
                Pill(text: "Needs key", color: Theme.warning)
            } else {
                Pill(text: "Ready", color: Theme.ok)
            }
        }
    }
}

struct ServicesSettingsView: View {
    @Environment(AppState.self) private var app
    @State private var adding: ServiceKind?

    var body: some View {
        List {
            ForEach(ServiceKind.allCases) { kind in
                let list = app.services.filter { $0.kind == kind }
                Section {
                    ForEach(list) { instance in
                        NavigationLink { ServiceEditorView(instance: instance) } label: { ServiceRow(instance: instance) }
                    }
                    .onDelete { offsets in offsets.map { list[$0].id }.forEach(app.remove) }
                    if list.isEmpty || kind.allowsMultiple {
                        Button { adding = kind } label: { Label(list.isEmpty ? "Add \(kind.displayName)" : "Add another \(kind.displayName)", systemImage: "plus") }
                    }
                } header: {
                    Text("\(kind.displayName) · \(kind.role)")
                }
            }
        }
        .navigationTitle("Services")
        .sheet(item: $adding) { kind in
            NavigationStack {
                ServiceEditorView(instance: ServiceInstance(kind: kind, name: app.services.contains { $0.kind == kind } ? "\(kind.displayName) 2" : nil, url: app.services.contains { $0.kind == kind } ? "" : nil), isNew: true)
            }
        }
    }
}

struct ServiceEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var instance: ServiceInstance
    var isNew = false
    @State private var testing = false
    @State private var testResult: ProbeResult?
    @State private var jellyfinUser = ""
    @State private var jellyfinPassword = ""
    @State private var signingIn = false
    @State private var showKey = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $instance.name)
                TextField("Address", text: $instance.url, prompt: Text(instance.kind.defaultURL))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("serviceURLField")
                if instance.kind == .qbittorrent {
                    TextField("Username", text: Binding(get: { instance.username ?? "" }, set: { instance.username = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                HStack {
                    Group {
                        let label = instance.kind == .qbittorrent ? "Password" : "API key"
                        if showKey { TextField(label, text: $instance.apiKey) } else { SecureField(label, text: $instance.apiKey) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("apiKeyField")
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showKey ? "Hide key" : "Show key")
                }
                Toggle("Enabled", isOn: $instance.enabled)
            } header: {
                Text("Connection")
            } footer: {
                Text("API key: \(instance.kind.apiKeyHint).")
            }

            if instance.kind == .jellyfin {
                Section {
                    TextField("Username", text: $jellyfinUser).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $jellyfinPassword)
                    Button { signIn() } label: {
                        if signingIn { ProgressView() } else { Text("Sign in and use this account") }
                    }
                    .disabled(jellyfinUser.isEmpty || signingIn)
                } header: {
                    Text("Or sign in to Jellyfin")
                } footer: {
                    Text(instance.username.map { "Signed in as \($0). The password is not stored, only the access token." } ?? "Use an administrator account. The password is not stored.")
                }
            }

            Section {
                Button { test() } label: {
                    HStack {
                        Text("Test connection")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || ServiceInstance.normalisedURL(instance.url) == nil)
                if let result = testResult {
                    if let error = result.error {
                        Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.error)
                    } else {
                        Label("Connected\(result.version.map { " · version \($0)" } ?? "")", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.ok)
                        ForEach(result.issues) { issue in
                            Label(issue.message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.color(issue.severity)).font(.footnote)
                        }
                    }
                }
            }
        }
        .navigationTitle(instance.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(ServiceInstance.normalisedURL(instance.url) == nil)
                    .accessibilityIdentifier("saveServiceButton")
            }
        }
    }

    private func save() {
        if let url = ServiceInstance.normalisedURL(instance.url) { instance.url = url.absoluteString }
        app.upsert(instance)
        app.show("\(instance.name) saved")
        dismiss()
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            do {
                testResult = await ServiceProbe.probe(instance, client: try app.client(instance))
            } catch {
                testResult = ProbeResult(instance: instance, version: nil, issues: [], error: AppState.describe(error))
            }
        }
    }

    private func signIn() {
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                var anonymous = instance
                anonymous.apiKey = ""
                let result = try await JellyfinClient(client: try app.client(anonymous)).authenticate(username: jellyfinUser, password: jellyfinPassword)
                guard result.user.isAdmin else {
                    app.show("\(result.user.name) is not a Jellyfin administrator; management features need an admin account.", error: true)
                    return
                }
                instance.apiKey = result.accessToken
                instance.username = result.user.name
                jellyfinPassword = ""
                app.show("Signed in as \(result.user.name)")
            } catch {
                app.show(AppState.describe(error), error: true)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        List {
            Section {
                NavigationLink { ServicesSettingsView() } label: {
                    Label("Services", systemImage: "server.rack")
                        .badge(app.services.filter { $0.enabled && $0.apiKey.isEmpty }.count)
                }
            }
            Section {
                Toggle(isOn: $app.appLockEnabled) { Label("Lock with Face ID / passcode", systemImage: "faceid") }
            } footer: {
                Text("Asks for Face ID, Touch ID or the device passcode whenever Streamero comes back from the background.")
            }
            Section("About") {
                LabeledContent("Version", value: "\(app.appVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                Link(destination: URL(string: "https://scyde.dev")!) {
                    LabeledContent("Developed by", value: "SCYDE")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
