import StreameroKit
import SwiftUI

struct MoreView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        List {
            Section("Services") {
                link(.jellyfin, "Jellyfin", "Streams, libraries, users, tasks") { JellyfinHomeView() }
                link(.seerr, "Requests", "Approve, decline, discover, issues") { RequestsView() }
                link(.radarr, "Movies", "Radarr library") { MoviesListView().navigationTitle("Movies") }
                link(.sonarr, "Series", "Sonarr library") { SeriesListView().navigationTitle("Series") }
                link(.lidarr, "Music", "Lidarr library") { ArtistsListView().navigationTitle("Music") }
                link(.prowlarr, "Indexers", "Prowlarr indexers and search") { IndexersView() }
                link(.bazarr, "Subtitles", "Bazarr wanted, history, providers") { SubtitlesView() }
            }
            Section {
                NavigationLink { SystemHealthView() } label: { Label("System health", systemImage: "stethoscope") }
                NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
            }
            Section {
                HStack(spacing: 12) {
                    BrandMark(size: 40)
                    VStack(alignment: .leading) {
                        Text("Streamero").font(Theme.titleFont)
                        Text("Version \(app.appVersion) · by SCYDE").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .navigationTitle("More")
    }

    private func link<Destination: View>(_ kind: ServiceKind, _ title: String, _ subtitle: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 12) {
                Image(systemName: Theme.icon(kind)).foregroundStyle(Theme.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if app.instances(kind).isEmpty { Pill(text: "Not set up", color: Theme.warning) }
            }
        }
    }
}
