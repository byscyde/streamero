import StreameroCore
import SwiftUI

/// Square (or circular for artists) artwork with a bold title and a grey, two-line subtitle.
struct MediaCard: View {
    let title: String
    var subtitle: String?
    let artwork: URL?
    var mosaic: [URL] = []
    var circular = false
    var size: CGFloat = Theme.Size.card
    var symbol = "music.note"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Group {
                if !mosaic.isEmpty && artwork == nil {
                    MosaicArtwork(urls: mosaic, size: size)
                } else {
                    ArtworkView(url: artwork, size: size, placeholderSymbol: symbol, circular: circular)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(circular ? 1 : 2)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2) }
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
        MediaCard(title: album.title, subtitle: [album.releaseYear, album.artist.name].compactMap { $0 }.joined(separator: " • "), artwork: album.artworkUrl, size: size, symbol: "square.stack")
    }
}

struct ArtistCard: View {
    let artist: Artist
    var size: CGFloat = Theme.Size.card
    var body: some View {
        MediaCard(title: artist.name, subtitle: "Artist", artwork: artist.artworkUrl, circular: true, size: size, symbol: "music.mic")
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var size: CGFloat = Theme.Size.card
    var body: some View {
        MediaCard(title: playlist.title, subtitle: playlist.isEditorial ? "Playlist" : "Playlist • \(playlist.owner?.displayName ?? "")", artwork: playlist.artworkUrl, mosaic: playlist.mosaicUrls, size: size, symbol: "music.note.list")
    }
}

/// Generated cover for a personal mix: artwork (mosaic when available) with a coloured band and the mix name.
struct MixArtwork: View {
    let mix: Mix
    var size: CGFloat = Theme.Size.card

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let urls = mix.artworkUrls, urls.count >= 4 {
                MosaicArtwork(urls: urls, size: size)
            } else if let first = mix.artworkUrls?.first {
                ArtworkView(url: first, size: size, placeholderSymbol: "sparkles")
            } else {
                Rectangle().fill(tint.gradient)
                    .overlay(Image(systemName: mix.kind == "artist" ? "music.mic" : "sparkles").font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(.white.opacity(0.9)))
            }
            if size >= 100 {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    Text(mix.title)
                        .font(.system(size: size * 0.11, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .padding(.horizontal, size * 0.06)
                        .padding(.bottom, size * 0.08)
                    Rectangle().fill(tint).frame(height: size * 0.04)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
    }

    /// Stable per-mix colour so each mix keeps its look between launches.
    private var tint: Color {
        let colours: [UInt32] = [0xE8115B, 0x1E3264, 0x8D67AB, 0xE13300, 0x148A08, 0x509BF5, 0xBA5D07, 0x7358FF]
        let hash = mix.id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hex: colours[Int(hash % UInt32(colours.count))])
    }
}

struct MixCard: View {
    let mix: Mix
    var size: CGFloat = Theme.Size.card
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            MixArtwork(mix: mix, size: size)
            Text(mix.description).font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2).frame(width: size, alignment: .leading)
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
            Text(video.title).font(Theme.Typography.callout.weight(.semibold)).lineLimit(2)
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
            Theme.Palette.surfaceHighlight
            if let image { Image(uiImage: image).resizable().scaledToFill() } else {
                Image(systemName: "play.rectangle").font(.title).foregroundStyle(Theme.Gradients.brand)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .task(id: url) {
            guard let u = artworkURL(url, points: 600) else { return }
            image = await ImagePipeline.shared.image(for: u, pixelSize: width * scale)
        }
    }
}

/// Horizontal shelf with a header.
struct Shelf<Item: Identifiable, Card: View>: View {
    let title: String
    var subtitle: String?
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title: title, subtitle: subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.m) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, Theme.Spacing.screen)
            }
            .scrollClipDisabled()
        }
    }
}

/// List row used by Search results and Your Library: artwork, title and a grey "Type • Owner" line.
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
                Text(title).font(.system(size: 16)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
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
