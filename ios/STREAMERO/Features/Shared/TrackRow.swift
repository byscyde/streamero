import StreameroCore
import SwiftUI

struct TrackRow: View {
    let track: Track
    var index: Int?
    var showArtwork = true
    var subtitle: String?
    let onPlay: () -> Void

    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: Theme.Spacing.m) {
                if let index, !showArtwork {
                    ZStack {
                        if isCurrent && player.isPlaying {
                            NowPlayingBars().frame(width: 16, height: 14)
                        } else {
                            Text("\(index)").font(Theme.Typography.callout.monospacedDigit()).foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        }
                    }
                    .frame(width: 28)
                }
                if showArtwork {
                    ArtworkView(url: track.artworkUrl, size: Theme.Size.rowArtwork)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if track.explicit { ExplicitBadge() }
                        if downloads.localFile(forTrack: track.id) != nil {
                            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(Theme.Palette.turquoise).accessibilityLabel("Downloaded")
                        }
                        Text(subtitle ?? track.artist.name)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if library.contains(.track, track.id) {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.Palette.violet).accessibilityLabel("Liked")
                }
                TrackMenu(track: track) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More options for \(track.title)")
            }
            .padding(.horizontal, Theme.Spacing.screen)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu { TrackMenuItems(track: track) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title), \(track.artist.name)\(track.explicit ? ", explicit" : "")")
        .accessibilityHint("Plays the song")
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.Palette.surfaceRaised : Color.clear)
    }
}

struct TrackMenu<Label: View>: View {
    let track: Track
    @ViewBuilder let label: () -> Label
    var body: some View {
        Menu { TrackMenuItems(track: track) } label: { label() }
    }
}

/// The actions offered for any track, wherever it appears.
struct TrackMenuItems: View {
    let track: Track
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        let liked = library.contains(.track, track.id)
        Button { player.playNext([track]); model.show("Playing next", symbol: "text.line.first.and.arrowtriangle.forward") } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue([track]); model.show("Added to queue", symbol: "text.append") } label: { Label("Add to queue", systemImage: "text.append") }
        Button { model.toggleLike(track) } label: { Label(liked ? "Remove from Liked Songs" : "Add to Liked Songs", systemImage: liked ? "heart.slash" : "heart") }
        Button { model.addToPlaylist = AddToPlaylistRequest(tracks: [track]) } label: { Label("Add to playlist…", systemImage: "text.badge.plus") }
        if track.downloadable {
            if let record = downloads.record("track", track.id) {
                Button(role: .destructive) { downloads.delete(record) } label: { Label("Remove download", systemImage: "trash") }
            } else {
                Button { Task { await downloads.download(track: track) }; model.show("Downloading", symbol: "arrow.down.circle") } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
        Divider()
        NavigationLink(value: Route.artist(track.artist.id)) { Label("Go to artist", systemImage: "music.mic") }
        if let album = track.album {
            NavigationLink(value: Route.album(album.id)) { Label("Go to album", systemImage: "square.stack") }
        }
        if let videoId = track.videoId {
            NavigationLink(value: Route.video(videoId)) { Label("Watch music video", systemImage: "play.rectangle") }
        }
        if let url = model.serverURL?.appendingPathComponent("v1/tracks/\(track.id)") {
            ShareLink(item: url, subject: Text(track.title), message: Text("\(track.title) — \(track.artist.name) on STREAMERO")) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

/// Animated equaliser glyph for the playing row.
struct NowPlayingBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion {
            Image(systemName: "waveform").foregroundStyle(Theme.Palette.accent)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(Theme.Gradients.brand)
                            .frame(width: 3, height: 4 + 10 * abs(sin(t * (3 + Double(i)) + Double(i))))
                    }
                }
            }
        }
    }
}
