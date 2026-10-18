import CarPlay
import StreameroCore
import UIKit

/// CarPlay audio experience built only from Apple's templates (tab bar, list, Now Playing).
/// Requires the com.apple.developer.carplay-audio entitlement granted by Apple (see docs/CARPLAY.md).
/// Video is never offered on the car display. Search is not available to audio apps in CarPlay;
/// drivers use Siri instead.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        MainActor.assumeIsolated {
            let tabs = CPTabBarTemplate(templates: [homeTemplate(), libraryTemplate(), recentTemplate()])
            interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
            CPNowPlayingTemplate.shared.isUpNextButtonEnabled = true
            CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = false
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([
                CPNowPlayingShuffleButton { _ in MainActor.assumeIsolated { AppModel.shared.map { $0.player.setShuffle(!$0.player.queue.shuffle) } } },
                CPNowPlayingRepeatButton { _ in MainActor.assumeIsolated { AppModel.shared?.player.cycleRepeat() } },
            ])
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    // MARK: Templates

    @MainActor private func homeTemplate() -> CPListTemplate {
        let t = CPListTemplate(title: "Home", sections: [CPListSection(items: [loadingItem()])])
        t.tabImage = UIImage(systemName: "house.fill")
        Task { @MainActor in
            guard let api = AppModel.shared?.api else { return }
            var sections: [CPListSection] = []
            if let mixes = try? await api.mixes(), !mixes.isEmpty {
                sections.append(CPListSection(items: mixes.prefix(8).map { mix in
                    let item = CPListItem(text: mix.title, detailText: mix.description, image: UIImage(systemName: "sparkles"))
                    item.accessoryType = .disclosureIndicator
                    item.handler = { [weak self] _, done in
                        Task { @MainActor in
                            if let detail = try? await api.mix(mix.id) {
                                self?.play(detail.items.map(\.track), context: PlaybackContext(type: "mix", id: nil, title: mix.title))
                            }
                            done()
                        }
                    }
                    return item
                }, header: "Made for you", sectionIndexTitle: nil))
            }
            if let trending = try? await api.trending(), !trending.isEmpty {
                sections.append(CPListSection(items: trackItems(Array(trending.prefix(15)), context: PlaybackContext(type: "radio", title: "Trending")), header: "Trending", sectionIndexTitle: nil))
            }
            t.updateSections(sections.isEmpty ? [CPListSection(items: [emptyItem("Nothing to play yet")])] : sections)
        }
        return t
    }

    @MainActor private func libraryTemplate() -> CPListTemplate {
        let liked = CPListItem(text: "Liked Songs", detailText: nil, image: UIImage(systemName: "heart.fill"))
        liked.accessoryType = .disclosureIndicator
        liked.handler = { [weak self] _, done in
            Task { @MainActor in
                guard let api = AppModel.shared?.api else { done(); return }
                let tracks = (try? await api.likedTracks(limit: 100))?.items ?? AppModel.shared?.downloads.completedTracks ?? []
                self?.push(title: "Liked Songs", items: self?.trackItems(tracks, context: PlaybackContext(type: "liked", title: "Liked Songs")) ?? [])
                done()
            }
        }
        let downloaded = CPListItem(text: "Downloaded", detailText: nil, image: UIImage(systemName: "arrow.down.circle.fill"))
        downloaded.accessoryType = .disclosureIndicator
        downloaded.handler = { [weak self] _, done in
            Task { @MainActor in
                let tracks = AppModel.shared?.downloads.completedTracks ?? []
                self?.push(title: "Downloaded", items: self?.trackItems(tracks, context: PlaybackContext(type: "downloads", title: "Downloaded")) ?? [])
                done()
            }
        }
        let playlists = CPListItem(text: "Playlists", detailText: nil, image: UIImage(systemName: "music.note.list"))
        playlists.accessoryType = .disclosureIndicator
        playlists.handler = { [weak self] _, done in
            Task { @MainActor in
                guard let self, let api = AppModel.shared?.api, let page = try? await api.myPlaylists(limit: 100) else { done(); return }
                self.push(title: "Playlists", items: page.items.map { p in
                    let item = CPListItem(text: p.title, detailText: Format.count(p.itemCount, "song"), image: UIImage(systemName: "music.note.list"))
                    item.accessoryType = .disclosureIndicator
                    item.handler = { [weak self] _, inner in
                        Task { @MainActor in
                            if let detail = try? await api.playlist(p.id) {
                                let tracks = detail.items.items.compactMap(\.track)
                                self?.push(title: p.title, items: self?.trackItems(tracks, context: PlaybackContext(type: "playlist", id: p.id, title: p.title)) ?? [])
                            }
                            inner()
                        }
                    }
                    return item
                })
                done()
            }
        }
        let albums = CPListItem(text: "Albums", detailText: nil, image: UIImage(systemName: "square.stack.fill"))
        albums.accessoryType = .disclosureIndicator
        albums.handler = { [weak self] _, done in
            Task { @MainActor in
                guard let self, let api = AppModel.shared?.api, let page = try? await api.savedAlbums(limit: 100) else { done(); return }
                self.push(title: "Albums", items: page.items.map { a in
                    let item = CPListItem(text: a.title, detailText: a.artist.name, image: UIImage(systemName: "square.stack"))
                    item.accessoryType = .disclosureIndicator
                    item.handler = { [weak self] _, inner in
                        Task { @MainActor in
                            if let detail = try? await api.album(a.id) {
                                self?.push(title: a.title, items: self?.trackItems(detail.tracks, context: PlaybackContext(type: "album", id: a.id, title: a.title)) ?? [])
                            }
                            inner()
                        }
                    }
                    self.loadArtwork(a.artworkUrl, into: item)
                    return item
                })
                done()
            }
        }
        let artists = CPListItem(text: "Artists", detailText: nil, image: UIImage(systemName: "music.mic"))
        artists.accessoryType = .disclosureIndicator
        artists.handler = { [weak self] _, done in
            Task { @MainActor in
                guard let self, let api = AppModel.shared?.api, let page = try? await api.followedArtists(limit: 100) else { done(); return }
                self.push(title: "Artists", items: page.items.map { a in
                    let item = CPListItem(text: a.name, detailText: nil, image: UIImage(systemName: "music.mic"))
                    item.accessoryType = .disclosureIndicator
                    item.handler = { [weak self] _, inner in
                        Task { @MainActor in
                            if let detail = try? await api.artist(a.id) {
                                self?.push(title: a.name, items: self?.trackItems(detail.topTracks, context: PlaybackContext(type: "artist", id: a.id, title: a.name)) ?? [])
                            }
                            inner()
                        }
                    }
                    self.loadArtwork(a.artworkUrl, into: item)
                    return item
                })
                done()
            }
        }
        let t = CPListTemplate(title: "Library", sections: [CPListSection(items: [liked, playlists, albums, artists, downloaded])])
        t.tabImage = UIImage(systemName: "square.stack.fill")
        return t
    }

    @MainActor private func recentTemplate() -> CPListTemplate {
        let t = CPListTemplate(title: "Recent", sections: [CPListSection(items: [loadingItem()])])
        t.tabImage = UIImage(systemName: "clock.fill")
        Task { @MainActor in
            let tracks = (try? await AppModel.shared?.api?.recentlyPlayed(limit: 30))?.items ?? []
            t.updateSections([CPListSection(items: tracks.isEmpty ? [emptyItem("No recent plays")] : trackItems(tracks, context: PlaybackContext(type: "radio", title: "Recently played")))])
        }
        return t
    }

    // MARK: Helpers

    @MainActor private func trackItems(_ tracks: [Track], context: PlaybackContext) -> [CPListItem] {
        let limit = min(tracks.count, CPListTemplate.maximumItemCount)
        return tracks.prefix(limit).enumerated().map { index, track in
            let item = CPListItem(text: track.title, detailText: track.artist.name, image: UIImage(systemName: "music.note"))
            item.isExplicitContent = track.explicit
            item.playingIndicatorLocation = .trailing
            item.isPlaying = AppModel.shared?.player.current?.id == track.id
            item.handler = { [weak self] _, done in
                Task { @MainActor in
                    self?.play(Array(tracks.prefix(limit)), startAt: index, context: context)
                    done()
                }
            }
            loadArtwork(track.artworkUrl, into: item)
            return item
        }
    }

    @MainActor private func play(_ tracks: [Track], startAt: Int = 0, context: PlaybackContext) {
        guard !tracks.isEmpty else { return }
        AppModel.shared?.player.play(tracks: tracks, startAt: startAt, context: context)
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    @MainActor private func push(title: String, items: [CPListItem]) {
        let t = CPListTemplate(title: title, sections: [CPListSection(items: items.isEmpty ? [emptyItem("Nothing here yet")] : items)])
        interfaceController?.pushTemplate(t, animated: true, completion: nil)
    }

    @MainActor private func loadArtwork(_ url: URL?, into item: CPListItem) {
        guard let url = artworkURL(url, points: 100) else { return }
        Task { @MainActor in
            if let image = await ImagePipeline.shared.image(for: url, pixelSize: CPListItem.maximumImageSize.width * 3) { item.setImage(image) }
        }
    }

    @MainActor private func loadingItem() -> CPListItem { CPListItem(text: "Loading…", detailText: nil) }
    @MainActor private func emptyItem(_ text: String) -> CPListItem { CPListItem(text: text, detailText: nil) }
}
