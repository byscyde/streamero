import StreameroKit
import SwiftUI

enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let surface = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let surfaceRaised = Color(red: 0.137, green: 0.137, blue: 0.153)
    static let accent = Color(red: 0.890, green: 0.118, blue: 0.176)
    static let textSecondary = Color(white: 0.63)
    static let ok = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let warning = Color(red: 1.0, green: 0.70, blue: 0.20)
    static let error = Color(red: 0.95, green: 0.33, blue: 0.36)
    static let titleFont = Font.system(.headline, design: .monospaced).weight(.bold)

    static func color(_ severity: HealthSeverity) -> Color {
        switch severity {
        case .ok: ok
        case .notice: .blue
        case .warning: warning
        case .error: error
        }
    }

    static func icon(_ kind: ServiceKind) -> String {
        switch kind {
        case .jellyfin: "play.tv.fill"
        case .seerr: "tray.and.arrow.down.fill"
        case .sonarr: "tv"
        case .radarr: "film"
        case .lidarr: "music.note"
        case .prowlarr: "magnifyingglass.circle"
        case .bazarr: "captions.bubble"
        case .qbittorrent: "arrow.down.to.line.compact"
        case .sabnzbd: "tray.full"
        }
    }
}

/// Rounded panel used throughout the app.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true) }
}

struct Pill: View {
    var text: String
    var color: Color = Theme.textSecondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct Poster: View {
    var url: URL?
    var width: CGFloat = 54
    var aspect: CGFloat = 1.5
    var symbol = "photo"
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default:
                ZStack {
                    Theme.surfaceRaised
                    Image(systemName: symbol).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(width: width, height: width * aspect)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct ProgressBar: View {
    var value: Double
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(color).frame(width: geo.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 5)
        .accessibilityValue(Format.percent(value))
    }
}

/// Shown when a feature needs a service that isn't configured.
struct NotConfiguredView: View {
    var kind: ServiceKind
    var body: some View {
        ContentUnavailableView {
            Label("\(kind.displayName) is not set up", systemImage: Theme.icon(kind))
        } description: {
            Text("Add its address and API key in Settings → Services.")
        } actions: {
            NavigationLink("Open Settings") { ServicesSettingsView() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ErrorStateView: View {
    var message: String
    var retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: retry).buttonStyle(.borderedProminent)
        }
    }
}

/// Picker shown when there are several instances of one service (e.g. Jellyseerr and Overseerr).
struct InstancePicker: View {
    var instances: [ServiceInstance]
    @Binding var selection: UUID?
    var body: some View {
        if instances.count > 1 {
            Picker("Server", selection: $selection) {
                ForEach(instances) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Toast banner for action results.
struct ToastView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if let toast = app.toast {
            Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(toast.isError ? Theme.error : Color(white: 0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(toast.isError ? 5 : 2.5))
                    withAnimation { app.toast = nil }
                }
                .onTapGesture { withAnimation { app.toast = nil } }
        }
    }
}

extension Date {
    var relative: String { formatted(.relative(presentation: .named)) }
}
