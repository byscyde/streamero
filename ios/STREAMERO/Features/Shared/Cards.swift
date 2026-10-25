import StreameroCore
import SwiftUI

/// Big square artwork with a monospace title and a grey "Album • Artist" caption.
struct MediaCard: View {
    let title: String
    var subtitle: String?
    let artwork: URL?
    var mosaic: [URL] = []
    var circular = false
    var size: CGFloat = Theme.Size.card
    var symbol = "music.note"

    var body: some View {
        VStack(alignment: circular ? .center : .leading, spacing: Theme.Spacing.s) {
            Group {
                if !mosaic.isEmpty && artwork == nil {
                    MosaicArtwork(urls: mosaic, size: size, cornerRadius: Theme.Radius.card)
                } else {
                    ArtworkView(url: artwork, size: size, cornerRadius: Theme.Radius.card, placeholderSymbol: symbol, circular: circular)
                }
            }
            VStack(alignment: circular ? .center : .leading, spacing: 2) {
                Text(title)
                    .font(circular ? Font.system(size: 16, weight: .medium) : Theme.Typography.media(15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: circular ? .center : .leading)
            .multilineTextAlignment(circular ? .center : .leading)
        }
        .frame(width: size)
        .accessibilityElement(children: .combine)
    }
}

struct AlbumCard: View {
    let album: Album
    var size: CGFloat = Theme.Size.card
    var body: some View {
        MediaCard(title: album.title, subtitle: "\(album.typeLabel) • \(album.artist.name)", artwork: album.artworkUrl, size: size, symbol: "square.stack")
    }
}

extension Album {
    /// "Album", "Single", "EP", "Compilation".
    var typeLabel: String {
        switch albumType.lowercased() {
        case "single": "Single"
        case "ep": "EP"
        case "compilation": "Compilation"
        default: "Album"
        }
    }
}

/// Round "Top artist" avatar with name and follower count.
struct ArtistCard: View {
    let artist: Artist
    var size: CGFloat = Theme.Size.artistAvatar
    var body: some View {
        MediaCard(title: artist.name, subtitle: artist.followerCount.map { "\(Format.compact($0)) followers" } ?? "Artist",
                  artwork: artist.artworkUrl, circular: true, size: size, symbol: "music.mic")
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var size: CGFloat = Theme.Size.card
    var body: some View {
        MediaCard(title: playlist.title, subtitle: playlist.isEditorial ? "Playlist" : "Playlist • \(playlist.owner?.displayName ?? "")", artwork: playlist.artworkUrl, mosaic: playlist.mosaicUrls, size: size, symbol: "music.note.list")
    }
}

/// "Recommended playlists": large cover with the playlist name set over a dark scrim, mono and bold.
struct BigPlaylistCard: View {
    let playlist: Playlist
    var size: CGFloat = Theme.Size.bigCard
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if playlist.artworkUrl == nil && playlist.mosaicUrls.count >= 4 {
                MosaicArtwork(urls: playlist.mosaicUrls, size: size, cornerRadius: 0)
            } else {
                ArtworkView(url: playlist.artworkUrl ?? playlist.mosaicUrls.first, size: size, cornerRadius: 0, placeholderSymbol: "music.note.list")
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            Text(playlist.title.uppercased())
                .underline(true, color: .white)
                .font(Theme.Typography.media(size * 0.12, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(size * 0.07)
            BrandGlyph(size: size * 0.12)
                .padding(size * 0.05)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(playlist.title), playlist")
    }
}

/// Generated cover for a personal mix: artwork (mosaic when available) with a red band and the mix name.
struct MixArtwork: View {
    let mix: Mix
    var size: CGFloat = Theme.Size.card

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let urls = mix.artworkUrls, urls.count >= 4 {
                MosaicArtwork(urls: urls, size: size, cornerRadius: 0)
            } else if let first = mix.artworkUrls?.first {
                ArtworkView(url: first, size: size, cornerRadius: 0, placeholderSymbol: "sparkles")
            } else {
                Rectangle().fill(Theme.Gradients.genre(mix.id))
                    .overlay(Image(systemName: mix.kind == "artist" ? "music.mic" : "sparkles").font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(.white.opacity(0.9)))
            }
            if size >= 100 {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    Text(mix.title)
                        .font(Theme.Typography.media(size * 0.1, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(.horizontal, size * 0.06)
                        .padding(.bottom, size * 0.08)
                    Rectangle().fill(Theme.Palette.accent).frame(height: size * 0.035)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

struct MixCard: View {
    let mix: Mix
    var size: CGFloat = Theme.Size.card
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            MixArtwork(mix: mix, size: size)
            Text(mix.description).font(.system(size: 13)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2).frame(width: size, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mix.title)
    }
}

struct VideoCard: View {
    let video: Video
    var width: CGFloat = 240
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ZStack(alignment: .bottomTrailing) {
                VideoThumbnail(url: video.thumbnailUrl, width: width)
                Text(Format.time(video.duration))
                    .font(Theme.Typography.micro.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
            .overlay(alignment: .bottom) {
                if let p = video.progress, !p.completed, video.durationMs > 0 {
                    GeometryReader { geo in
                        Capsule().fill(Theme.Palette.accent).frame(width: geo.size.width * CGFloat(p.positionMs) / CGFloat(video.durationMs), height: 3)
                    }
                    .frame(height: 3)
                }
            }
            Text(video.title).font(Theme.Typography.media(14, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
            if let artist = video.artist { Text(artist.name).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary) }
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
    }
}

struct VideoThumbnail: View {
    let url: URL?
    let width: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Theme.Palette.surfaceRaised
            if let image { Image(uiImage: image).resizable().scaledToFill() } else {
                Image(systemName: "play.rectangle").font(.title).foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .task(id: url) {
            guard let u = artworkURL(url, points: 600) else { return }
            image = await ImagePipeline.shared.image(for: u, pixelSize: width * scale)
        }
    }
}

/// Horizontal shelf with a header (and an optional "More" pill).
struct Shelf<Item: Identifiable, Card: View>: View {
    let title: String
    var subtitle: String?
    var more: Route?
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: title, subtitle: subtitle, more: more)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.l) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, Theme.Spacing.screen)
            }
            .scrollClipDisabled()
        }
    }
}

/// Horizontal row of gradient genre chips.
struct GenreChipRow: View {
    let names: [(name: String, kind: String)]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Theme.Spacing.s) {
                ForEach(Array(names.enumerated()), id: \.offset) { _, g in
                    NavigationLink(value: Route.tag(kind: g.kind, name: g.name)) { GenreChip(name: g.name.capitalized) }
                        .buttonStyle(PressScaleStyle())
                }
            }
            .padding(.horizontal, Theme.Spacing.screen)
        }
    }
}

/// List row used by Search results and Your Library: artwork, mono title and a grey "Type • Owner" line.
struct MediaRow: View {
    let title: String
    var subtitle: String?
    var artwork: URL?
    var mosaic: [URL] = []
    var circular = false
    var symbol = "music.note"
    var pinned = false
    var size: CGFloat = 56

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Group {
                if !mosaic.isEmpty && artwork == nil {
                    MosaicArtwork(urls: mosaic, size: size)
                } else {
                    ArtworkView(url: artwork, size: size, placeholderSymbol: symbol, circular: circular)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Typography.media(16)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                HStack(spacing: 4) {
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.Palette.accent).rotationEffect(.degrees(45)) }
                    if let subtitle { Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
