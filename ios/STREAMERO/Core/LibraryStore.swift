import Foundation
import Observation
import StreameroCore

/// Which tracks/albums/artists/videos/playlists the user saved. Toggles apply instantly (optimistic),
/// are queued durably, and flushed to the server; the queue survives offline use and app restarts.
@MainActor
@Observable
final class LibraryStore {
    private(set) var liked = Set<String>()
    private(set) var albums = Set<String>()
    private(set) var artists = Set<String>()
    private(set) var videos = Set<String>()
    private(set) var playlists = Set<String>()
    private(set) var revision = 0

    private var queue: LibraryChangeQueue
    private var api: APIClient?
    private var flushing = false

    init() {
        queue = JSONFileStore.load(LibraryChangeQueue.self, from: "library-queue") ?? LibraryChangeQueue()
        if let cached = JSONFileStore.load(LibraryIds.self, from: "library-ids") { apply(cached) }
    }

    func attach(api: APIClient?) { self.api = api }

    func contains(_ type: LibraryItemType, _ id: String) -> Bool {
        switch type {
        case .track: liked.contains(id)
        case .album: albums.contains(id)
        case .artist: artists.contains(id)
        case .video: videos.contains(id)
        case .playlist: playlists.contains(id)
        }
    }

    func toggle(_ type: LibraryItemType, _ id: String) {
        set(type, id, saved: !contains(type, id))
    }

    func set(_ type: LibraryItemType, _ id: String, saved: Bool) {
        mutate(type) { set in
            if saved { set.insert(id) } else { set.remove(id) }
        }
        queue.record(LibraryChange(type: type, id: id, op: saved ? .add : .remove))
        JSONFileStore.save(queue, to: "library-queue")
        revision += 1
        Task { await flush() }
    }

    private func mutate(_ type: LibraryItemType, _ f: (inout Set<String>) -> Void) {
        switch type {
        case .track: f(&liked)
        case .album: f(&albums)
        case .artist: f(&artists)
        case .video: f(&videos)
        case .playlist: f(&playlists)
        }
    }

    private func apply(_ ids: LibraryIds) {
        liked = Set(ids.tracks); albums = Set(ids.albums); artists = Set(ids.artists); videos = Set(ids.videos); playlists = Set(ids.playlists)
        // Re-apply local, not-yet-synced edits on top of server state.
        for c in queue.pending {
            mutate(c.type) { set in
                if c.op == .add { set.insert(c.id) } else { set.remove(c.id) }
            }
        }
    }

    /// Pushes pending edits, then refreshes from the server (picks up changes from other devices).
    func flush() async {
        guard let api, !flushing else { return }
        flushing = true
        defer { flushing = false }
        let batch = queue.batch()
        if !batch.isEmpty {
            do {
                try await api.syncLibrary(batch)
                queue.acknowledge(batch)
                JSONFileStore.save(queue, to: "library-queue")
            } catch { return }
        }
        await refresh()
    }

    func refresh() async {
        guard let api, let ids = try? await api.libraryIds() else { return }
        JSONFileStore.save(ids, to: "library-ids")
        apply(ids)
        revision += 1
    }

    func reset() {
        queue = LibraryChangeQueue()
        liked = []; albums = []; artists = []; videos = []; playlists = []
        JSONFileStore.remove("library-queue")
        JSONFileStore.remove("library-ids")
    }
}
