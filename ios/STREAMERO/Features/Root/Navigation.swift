import StreameroCore
import SwiftUI

enum Route: Hashable {
    case artist(String)
    case album(String)
    case playlist(String)
    case mix(String, String)
    case tag(kind: String, name: String)
    case video(String)
    case likedSongs
    case savedAlbums
    case followedArtists
    case playlists
    case downloads
    case recentlyPlayed
    case likedVideos
    case settings
    case profile
    case videos
    case youtube
    case genres
    case equalizer
    case section(SectionRef)
}

/// Hashable handle for a home/explore section, so "More" can push the full list.
struct SectionRef: Hashable {
    let section: HomeSection
    static func == (a: SectionRef, b: SectionRef) -> Bool { a.section.id == b.section.id && a.section.items == b.section.items }
    func hash(into hasher: inout Hasher) { hasher.combine(section.id) }
}

extension View {
    func streameroDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .artist(let id): ArtistView(id: id)
            case .album(let id): AlbumView(id: id)
            case .playlist(let id): PlaylistView(id: id)
            case .mix(let id, let title): MixView(id: id, title: title)
            case .tag(let kind, let name): TagTracksView(kind: kind, name: name)
            case .video(let id): VideoDetailView(id: id)
            case .likedSongs: LikedSongsView()
            case .savedAlbums: SavedAlbumsView()
            case .followedArtists: FollowedArtistsView()
            case .playlists: PlaylistsListView()
            case .downloads: DownloadsView()
            case .recentlyPlayed: RecentlyPlayedView()
            case .likedVideos: LikedVideosView()
            case .settings: SettingsView()
            case .profile: ProfileView()
            case .videos: VideosView()
            case .youtube: YouTubeDiscoveryView()
            case .genres: GenresView()
            case .equalizer: EqualizerView()
            case .section(let ref): SectionDetailView(section: ref.section)
            }
        }
    }
}

/// Route for a home/search item.
func route(for item: HomeItem) -> Route? {
    switch item {
    case .album(let a): .album(a.id)
    case .artist(let a): .artist(a.id)
    case .playlist(let p): .playlist(p.id)
    case .video(let v): .video(v.id)
    case .mix(let m): .mix(m.id, m.title)
    case .genre(let g): .tag(kind: "genre", name: g.name)
    case .mood(let g): .tag(kind: "mood", name: g.name)
    case .track, .unknown: nil
    }
}
