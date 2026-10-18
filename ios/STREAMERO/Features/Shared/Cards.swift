import StreameroCore
import SwiftUI

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
                    MosaicArtwork(urls: mosaic, size: size)
                } else {
                    ArtworkView(url: artwork, size: size, placeholderSymbol: symbol, circular: circular)
                }
            }
            .shadow(color: Theme.Shadow.cardColor, radius: 10, y: 6)
            VStack(alignment: circular ? .center : .leading, spacing: 2) {
                Text(title).font(Theme.Typography.callout.weight(.semibold)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                if let subtitle { Text(subtitle).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1) }
            }
        }
        .frame(width: size)
        .accessibilityElement(children: .combine)
    }
}

struct AlbumCard: View {
    let album: Album
    var size: CGFloat = Theme.Size.card
    var body: some View {
        MediaCard(title: album.title, subtitle: [album.releaseYear, album.artist.name].compactMap { $0 }.joined(separator: " · "), artwork: album.artworkUrl, size: size, symbol: "square.stack")
    }
}

struct ArtistCard: View {
    let artist: Artist
    var size: CGFloat = 120
    var body: some View {
        MediaCard(title: artist.name, subtitle: "Artist", artwork: artist.artworkUrl, circular: true, size: size, symbol: "music.mic")
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var size: CGFloat = Theme.Size.card
    var body: some View {
        MediaCard(title: playlist.title, subtitle: playlist.isEditorial ? "STREAMERO" : playlist.owner?.displayName, artwork: playlist.artworkUrl, mosaic: playlist.mosaicUrls, size: size, symbol: "music.note.list")
    }
}

struct MixCard: View {
    let mix: Mix
    var size: CGFloat = Theme.Size.card
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ZStack(alignment: .bottomLeading) {
                if let urls = mix.artworkUrls, urls.count >= 4 {
                    MosaicArtwork(urls: urls, size: size)
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous)
                        .fill(Theme.Gradients.brand)
                        .frame(width: size, height: size)
                        .overlay(Image(systemName: mix.kind == "artist" ? "dot.radiowaves.left.and.right" : "sparkles").font(.system(size: 40, weight: .bold)).foregroundStyle(.white.opacity(0.9)))
                }
                Text(mix.title)
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .padding(Theme.Spacing.s)
                    .lineLimit(2)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
            Text(mix.description).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2).frame(width: size, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
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
                        Capsule().fill(Theme.Gradients.brandHorizontal).frame(width: geo.size.width * CGFloat(p.positionMs) / CGFloat(video.durationMs), height: 3)
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
                LazyHStack(alignment: .top, spacing: Theme.Spacing.l) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, Theme.Spacing.screen)
            }
            .scrollClipDisabled()
        }
    }
}
