import Foundation

// MARK: - Shared

public struct Page<T: Codable & Sendable>: Codable, Sendable {
    public var items: [T]
    public var limit: Int
    public var offset: Int
    public var total: Int?
    public var nextOffset: Int?

    public init(items: [T], limit: Int = 30, offset: Int = 0, total: Int? = nil, nextOffset: Int? = nil) {
        self.items = items
        self.limit = limit
        self.offset = offset
        self.total = total
        self.nextOffset = nextOffset
    }
}

public struct ItemsResponse<T: Codable & Sendable>: Codable, Sendable {
    public var items: [T]
}

public struct ArtistRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct AlbumRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var artworkUrl: URL?
    public init(id: String, title: String, artworkUrl: URL? = nil) { self.id = id; self.title = title; self.artworkUrl = artworkUrl }
}

public struct SourceQuality: Codable, Sendable, Hashable {
    public var codec: String?
    public var container: String?
    public var lossless: Bool
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var bitrateKbps: Int?

    public init(codec: String? = nil, container: String? = nil, lossless: Bool, sampleRate: Int? = nil, bitDepth: Int? = nil, bitrateKbps: Int? = nil) {
        self.codec = codec; self.container = container; self.lossless = lossless
        self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.bitrateKbps = bitrateKbps
    }

    /// e.g. "FLAC · 24-bit / 48 kHz" or "AAC · 256 kbps"
    public var summary: String {
        var parts = [(codec ?? "?").uppercased()]
        if lossless, let depth = bitDepth, let rate = sampleRate {
            parts.append("\(depth)-bit / \(Self.khz(rate)) kHz")
        } else if let kbps = bitrateKbps {
            parts.append("\(kbps) kbps")
        }
        return parts.joined(separator: " · ")
    }

    static func khz(_ hz: Int) -> String {
        let v = Double(hz) / 1000
        return v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - Catalog

public struct Track: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var durationMs: Int
    public var explicit: Bool
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genres: [String]
    public var moods: [String]
    public var artist: ArtistRef
    public var album: AlbumRef?
    public var artworkUrl: URL?
    public var isLiked: Bool
    public var hasLyrics: Bool
    public var videoId: String?
    public var downloadable: Bool
    public var availableProfiles: [String]
    public var sourceQuality: SourceQuality?
    public var addedAt: Date?
    public var lastPlayedAt: Date?
    public var resumePositionMs: Int?

    public init(id: String, title: String, durationMs: Int, explicit: Bool = false, trackNumber: Int? = nil, discNumber: Int? = 1,
                genres: [String] = [], moods: [String] = [], artist: ArtistRef, album: AlbumRef? = nil, artworkUrl: URL? = nil,
                isLiked: Bool = false, hasLyrics: Bool = false, videoId: String? = nil, downloadable: Bool = true,
                availableProfiles: [String] = [], sourceQuality: SourceQuality? = nil) {
        self.id = id; self.title = title; self.durationMs = durationMs; self.explicit = explicit
        self.trackNumber = trackNumber; self.discNumber = discNumber; self.genres = genres; self.moods = moods
        self.artist = artist; self.album = album; self.artworkUrl = artworkUrl; self.isLiked = isLiked
        self.hasLyrics = hasLyrics; self.videoId = videoId; self.downloadable = downloadable
        self.availableProfiles = availableProfiles; self.sourceQuality = sourceQuality
    }

    public var duration: TimeInterval { TimeInterval(durationMs) / 1000 }
    public var supportsLossless: Bool { availableProfiles.contains(StreamProfile.lossless.rawValue) }
}

public struct Album: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var albumType: String
    public var releaseDate: String?
    public var genres: [String]
    public var label: String?
    public var explicit: Bool
    public var artworkUrl: URL?
    public var artist: ArtistRef
    public var trackCount: Int
    public var durationMs: Int
    public var isSaved: Bool?

    public var releaseYear: String? { releaseDate.map { String($0.prefix(4)) } }
}

public struct Artist: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var bio: String?
    public var genres: [String]
    public var artworkUrl: URL?
    public var followerCount: Int?
    public var isFollowed: Bool?
}

public struct SubtitleInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var language: String
    public var label: String
    public var kind: String
    public var isDefault: Bool
    public var forced: Bool
}

public struct VideoProgress: Codable, Sendable, Hashable {
    public var positionMs: Int
    public var completed: Bool
}

public struct Video: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var description: String?
    public var durationMs: Int
    public var explicit: Bool
    public var genres: [String]
    public var thumbnailUrl: URL?
    public var artist: ArtistRef?
    public var trackId: String?
    public var hasAudioOnly: Bool
    public var hasTimelinePreview: Bool
    public var subtitles: [SubtitleInfo]
    public var qualities: [Int]
    public var downloadable: Bool
    public var isLiked: Bool
    public var progress: VideoProgress?
    public var viewCount: Int

    public var duration: TimeInterval { TimeInterval(durationMs) / 1000 }
}

public struct PlaylistOwner: Codable, Sendable, Hashable {
    public var id: String
    public var displayName: String
}

public struct Playlist: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var description: String?
    public var visibility: String
    public var isCollaborative: Bool
    public var isEditorial: Bool
    public var owner: PlaylistOwner?
    public var artworkUrl: URL?
    public var mosaicUrls: [URL]
    public var itemCount: Int
    public var durationMs: Int
    public var version: Int
    public var isOwner: Bool
    public var canEdit: Bool
    public var isSaved: Bool
    public var shareUrl: URL?
}

public struct PlaylistItem: Codable, Sendable, Hashable, Identifiable {
    public var itemId: String
    public var position: Int
    public var track: Track?
    public var video: Video?
    public var id: String { itemId }
}

public struct PlaylistPage: Codable, Sendable {
    public var playlist: Playlist
    public var items: Page<PlaylistItem>
}

public struct ArtistReleases: Codable, Sendable {
    public var albums: [Album]
    public var singles: [Album]
    public var compilations: [Album]
}

public struct ArtistPage: Codable, Sendable {
    public var artist: Artist
    public var topTracks: [Track]
    public var releases: ArtistReleases
    public var videos: [Video]
    public var related: [Artist]
}

public struct AlbumPage: Codable, Sendable {
    public var album: Album
    public var tracks: [Track]
    public var moreByArtist: [Album]
    public var related: [Album]
}

public struct VideoPage: Codable, Sendable {
    public var video: Video
    public var related: [Video]
}

public struct LyricsResponse: Codable, Sendable {
    public struct Line: Codable, Sendable, Hashable {
        public var startMs: Int
        public var text: String
        public var words: [Word]?
    }
    public struct Word: Codable, Sendable, Hashable {
        public var startMs: Int
        public var text: String
    }
    public struct Attribution: Codable, Sendable, Hashable {
        public var source: String?
        public var license: String?
    }
    public var trackId: String
    public var synced: Bool
    public var language: String?
    public var lines: [Line]
    public var attribution: Attribution
}

public struct GenreInfo: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var trackCount: Int
    public var kind: String?
    public var id: String { name }
}

public struct GenresResponse: Codable, Sendable {
    public var genres: [GenreInfo]
    public var moods: [GenreInfo]
}

// MARK: - Discovery

public struct Mix: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var description: String
    public var artworkUrls: [URL]?
}

public struct ScoredTrack: Codable, Sendable, Hashable {
    public var track: Track
    public var score: Double
    public var reasons: [String]
}

public struct MixDetail: Codable, Sendable {
    public var mix: Mix
    public var items: [ScoredTrack]
}

public struct TagItem: Codable, Sendable, Hashable {
    public var name: String
    public var trackCount: Int
    public var artworkUrl: URL?
}

/// Home items are heterogeneous; the server tags each one with `type`.
public enum HomeItem: Codable, Sendable, Hashable, Identifiable {
    case track(Track)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case video(Video)
    case mix(Mix)
    case genre(TagItem)
    case mood(TagItem)
    case unknown(String)

    private enum Key: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .type)
        switch type {
        case "track": self = .track(try Track(from: decoder))
        case "album": self = .album(try Album(from: decoder))
        case "artist": self = .artist(try Artist(from: decoder))
        case "playlist": self = .playlist(try Playlist(from: decoder))
        case "video": self = .video(try Video(from: decoder))
        case "mix": self = .mix(try Mix(from: decoder))
        case "genre": self = .genre(try TagItem(from: decoder))
        case "mood": self = .mood(try TagItem(from: decoder))
        default: self = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .track(let v): try c.encode("track", forKey: .type); try v.encode(to: encoder)
        case .album(let v): try c.encode("album", forKey: .type); try v.encode(to: encoder)
        case .artist(let v): try c.encode("artist", forKey: .type); try v.encode(to: encoder)
        case .playlist(let v): try c.encode("playlist", forKey: .type); try v.encode(to: encoder)
        case .video(let v): try c.encode("video", forKey: .type); try v.encode(to: encoder)
        case .mix(let v): try c.encode("mix", forKey: .type); try v.encode(to: encoder)
        case .genre(let v): try c.encode("genre", forKey: .type); try v.encode(to: encoder)
        case .mood(let v): try c.encode("mood", forKey: .type); try v.encode(to: encoder)
        case .unknown(let t): try c.encode(t, forKey: .type)
        }
    }

    public var id: String {
        switch self {
        case .track(let v): "track:\(v.id)"
        case .album(let v): "album:\(v.id)"
        case .artist(let v): "artist:\(v.id)"
        case .playlist(let v): "playlist:\(v.id)"
        case .video(let v): "video:\(v.id)"
        case .mix(let v): "mix:\(v.id)"
        case .genre(let v): "genre:\(v.name)"
        case .mood(let v): "mood:\(v.name)"
        case .unknown(let t): "unknown:\(t)"
        }
    }
}

public struct HomeSection: Codable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var subtitle: String?
    public var layout: String
    public var items: [HomeItem]
}

public struct HomeFeed: Codable, Sendable {
    public var greeting: String
    public var isCatalogEmpty: Bool
    public var sections: [HomeSection]
}

public struct SearchResults: Codable, Sendable {
    public struct Genres: Codable, Sendable { public var items: [GenreInfo] }
    public var tracks: Page<Track>?
    public var artists: Page<Artist>?
    public var albums: Page<Album>?
    public var playlists: Page<Playlist>?
    public var videos: Page<Video>?
    public var genres: Genres?

    public var isEmpty: Bool {
        (tracks?.items.isEmpty ?? true) && (artists?.items.isEmpty ?? true) && (albums?.items.isEmpty ?? true)
            && (playlists?.items.isEmpty ?? true) && (videos?.items.isEmpty ?? true) && (genres?.items.isEmpty ?? true)
    }
}

public struct SearchResponse: Codable, Sendable {
    public var query: String
    public var results: SearchResults
}

public struct SearchSuggestion: Codable, Sendable, Hashable, Identifiable {
    public var text: String
    public var type: String
    public var id: String
}

public struct RecentSearch: Codable, Sendable, Hashable {
    public var query: String
}

// MARK: - Streaming

public struct TrackStream: Codable, Sendable {
    public struct Delivery: Codable, Sendable, Hashable {
        public var codec: String?
        public var bitrateKbps: Int?
        public var sampleRate: Int?
        public var bitDepth: Int?
        public var lossless: Bool
    }
    public var trackId: String
    public var requestedProfile: String
    public var profile: String
    public var url: URL
    public var expiresAt: Date
    public var mimeType: String
    public var durationMs: Int
    public var sizeBytes: Int
    public var delivery: Delivery
    public var source: SourceQuality
    public var availableProfiles: [String]
}

public struct VideoStream: Codable, Sendable {
    public struct Quality: Codable, Sendable, Hashable { public var height: Int; public var width: Int; public var bandwidth: Int; public var url: URL }
    public struct AudioTrack: Codable, Sendable, Hashable { public var language: String; public var name: String; public var isDefault: Bool }
    public struct Subtitle: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var language: String
        public var label: String
        public var kind: String
        public var isDefault: Bool
        public var forced: Bool
        public var vttUrl: URL
    }
    public struct AudioOnly: Codable, Sendable, Hashable { public var url: URL; public var expiresAt: Date; public var mimeType: String; public var bitrateKbps: Int? }
    public struct TimelinePreview: Codable, Sendable, Hashable {
        public var baseUrl: URL
        public var intervalSeconds: Double
        public var tileWidth: Int
        public var tileHeight: Int
        public var columns: Int
        public var rows: Int
        public var sheets: [String]
    }
    public var videoId: String
    public var durationMs: Int
    public var hlsUrl: URL
    public var expiresAt: Date
    public var qualities: [Quality]
    public var audioTracks: [AudioTrack]
    public var subtitles: [Subtitle]
    public var audioOnly: AudioOnly?
    public var timelinePreview: TimelinePreview?
}

// MARK: - Account

public struct User: Codable, Sendable, Hashable {
    public var id: String
    public var email: String
    public var displayName: String
    public var role: String
    public var emailVerified: Bool
    public var avatarUrl: String?
    public var allowExplicit: Bool?
    public var historyEnabled: Bool?
    public var personalizationEnabled: Bool?
    public var hasPassword: Bool?
    public var preferences: JSONValue?
    public var preferencesVersion: Int?
}

public struct Session: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresIn: Int
    public var tokenType: String
    public var user: User
}

public struct AuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var accessExpiresAt: Date

    public init(accessToken: String, refreshToken: String, accessExpiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.accessExpiresAt = accessExpiresAt
    }

    public init(session: Session, now: Date = Date()) {
        self.init(accessToken: session.accessToken, refreshToken: session.refreshToken, accessExpiresAt: now.addingTimeInterval(TimeInterval(session.expiresIn)))
    }
}

public struct LibrarySummary: Codable, Sendable {
    public var likedTracks: Int
    public var albums: Int
    public var artists: Int
    public var likedVideos: Int
    public var ownPlaylists: Int
    public var savedPlaylists: Int
    public var downloads: Int
}

public struct LibraryIds: Codable, Sendable {
    public var tracks: [String]
    public var albums: [String]
    public var artists: [String]
    public var videos: [String]
    public var playlists: [String]
}

public struct PlaybackStateResponse: Codable, Sendable {
    public var state: PlaybackSnapshot?
    public var version: Int
    public var deviceId: String?
}

public struct VersionResponse: Codable, Sendable { public var version: Int }

public struct DownloadGrant: Codable, Sendable, Hashable {
    public var grantId: String
    public var trackId: String?
    public var videoId: String?
    public var profile: String?
    public var url: URL?
    public var hlsUrl: URL?
    public var licenseExpiresAt: Date
    public var mimeType: String?
    public var sizeBytes: Int?
    public var checksumSha256: String?
    public var lossless: Bool?
}

public struct DownloadValidation: Codable, Sendable {
    public struct Valid: Codable, Sendable { public var grantId: String; public var licenseExpiresAt: Date }
    public var valid: [Valid]
    public var revoked: [String]
}

public struct YouTubeResult: Codable, Sendable, Hashable, Identifiable {
    public var videoId: String
    public var title: String
    public var channelTitle: String?
    public var thumbnailUrl: URL?
    public var embedUrl: URL
    public var watchUrl: URL
    public var id: String { videoId }
}

public struct YouTubeSearch: Codable, Sendable {
    public var items: [YouTubeResult]
    public var nextPageToken: String?
    public var attribution: String
}
