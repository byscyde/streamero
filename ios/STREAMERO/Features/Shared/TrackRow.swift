import StreameroCore
import SwiftUI

struct TrackRow: View {
    /// What sits at the right edge, before the ellipsis menu.
    enum Accessory { case duration, plays, playButton, none }

    let track: Track
    var index: Int?
    var showArtwork = true
    var subtitle: String?
    var accessory: Accessory = .duration
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
                            Text("\(index)").font(Theme.Typography.media(14, weight: .regular).monospacedDigit()).foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        }
                    }
                    .frame(width: 28)
                }
                if showArtwork {
                    ZStack {
                        ArtworkView(url: track.artworkUrl, size: Theme.Size.rowArtwork)
                        if isCurrent && player.isPlaying {
                            RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous).fill(.black.opacity(0.45))
                            NowPlayingBars().frame(width: 16, height: 14)
                        }
                    }
                    .frame(width: Theme.Size.rowArtwork, height: Theme.Size.rowArtwork)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(Theme.Typography.media(16))
                        .foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if track.explicit { ExplicitBadge() }
                        if downloads.localFile(forTrack: track.id) != nil {
                            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(Theme.Palette.accent).accessibilityLabel("Downloaded")
                        }
                        Text(subtitle ?? track.artist.name)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if library.contains(.track, track.id) {
                    Image(systemName: "heart.fill").font(.system(size: 13)).foregroundStyle(Theme.Palette.accent).accessibilityLabel("Liked")
                }
                accessoryView
                if accessory != .playButton {
                    TrackMenu(track: track) {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More options for \(track.title)")
                }
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

    @ViewBuilder private var accessoryView: some View {
        switch accessory {
        case .duration:
            Text(Format.time(track.duration)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
        case .plays:
            if let plays = track.playCount {
                Text("\(Format.compact(plays)) plays").font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
            } else {
                Text(Format.time(track.duration)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
            }
        case .playButton:
            Text(Format.time(track.duration)).font(.system(size: 14).monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
            Image(systemName: "play.fill").font(.system(size: 20)).foregroundStyle(Theme.Palette.textPrimary).frame(width: 40, height: 44)
        case .none:
            EmptyView()
        }
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.Palette.surfaceRaised.opacity(0.7) : Color.clear)
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
        if track.downloadable && AppearanceStore.shared.features.downloads {
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
        if let videoId = track.videoId, AppearanceStore.shared.features.videos {
            NavigationLink(value: Route.video(videoId)) { Label("Watch music video", systemImage: "play.rectangle") }
        }
        if let url = Optional(ServerConfig.url.appendingPathComponent("v1/tracks/\(track.id)")) {
            ShareLink(item: url, subject: Text(track.title), message: Text("\(track.title) — \(track.artist.name) on \(AppearanceStore.shared.brand.appName)")) { Label("Share", systemImage: "square.and.arrow.up") }
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
