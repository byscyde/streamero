import Foundation

public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one

    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// What is playing: either a catalog track or a video's separately prepared audio rendition.
public struct QueueItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case track, videoAudio }
    /// Unique per queue entry, so the same track may appear twice.
    public var id: String
    public var kind: Kind
    public var track: Track

    public init(track: Track, kind: Kind = .track, id: String = UUID().uuidString) {
        self.id = id; self.kind = kind; self.track = track
    }
}

public struct PlaybackContext: Codable, Sendable, Hashable {
    public var type: String // album, playlist, artist, mix, search, liked, radio
    public var id: String?
    public var title: String?
    public init(type: String, id: String? = nil, title: String? = nil) { self.type = type; self.id = id; self.title = title }
}

/// Pure queue state machine. The audio engine asks it what to play; it never touches AVFoundation.
public struct PlaybackQueue: Codable, Sendable, Equatable {
    public private(set) var items: [QueueItem] = []
    /// Order before shuffling, restored when shuffle is turned off.
    private var unshuffled: [QueueItem] = []
    public private(set) var currentIndex: Int?
    public private(set) var shuffle = false
    public var repeatMode: RepeatMode = .off
    public var context: PlaybackContext?

    public init() {}

    public var current: QueueItem? { currentIndex.flatMap { items.indices.contains($0) ? items[$0] : nil } }
    public var upNext: ArraySlice<QueueItem> {
        guard let i = currentIndex, i + 1 < items.count else { return [] }
        return items[(i + 1)...]
    }
    public var history: ArraySlice<QueueItem> {
        guard let i = currentIndex, i > 0 else { return [] }
        return items[..<i]
    }
    public var isEmpty: Bool { items.isEmpty }

    /// Replaces the queue. With shuffle on, `startAt` stays first and the rest is shuffled.
    public mutating func load<G: RandomNumberGenerator>(_ tracks: [Track], startAt: Int = 0, context: PlaybackContext? = nil, shuffle: Bool? = nil, using rng: inout G) {
        let entries = tracks.map { QueueItem(track: $0) }
        items = entries
        unshuffled = entries
        self.context = context
        currentIndex = entries.isEmpty ? nil : min(max(0, startAt), entries.count - 1)
        let wantShuffle = shuffle ?? self.shuffle
        self.shuffle = false
        if wantShuffle { setShuffle(true, using: &rng) }
    }

    public mutating func load(_ tracks: [Track], startAt: Int = 0, context: PlaybackContext? = nil, shuffle: Bool? = nil) {
        var rng = SystemRandomNumberGenerator()
        load(tracks, startAt: startAt, context: context, shuffle: shuffle, using: &rng)
    }

    public mutating func setShuffle<G: RandomNumberGenerator>(_ on: Bool, using rng: inout G) {
        guard on != shuffle else { return }
        shuffle = on
        let current = self.current
        if on {
            unshuffled = items
            var rest = items
            if let i = currentIndex { rest.remove(at: i) }
            rest.shuffle(using: &rng)
            items = (current.map { [$0] } ?? []) + rest
            currentIndex = current == nil ? nil : 0
        } else {
            // Restore original order, keeping entries added while shuffled (they go to the end).
            let present = Set(items.map(\.id))
            var restored = unshuffled.filter { present.contains($0.id) }
            let known = Set(restored.map(\.id))
            restored += items.filter { !known.contains($0.id) }
            items = restored
            currentIndex = current.flatMap { c in items.firstIndex { $0.id == c.id } }
        }
    }

    public mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }

    /// Index that follows the current one, honouring repeat. `userInitiated` skips ignore repeat-one.
    public func nextIndex(userInitiated: Bool) -> Int? {
        guard let i = currentIndex, !items.isEmpty else { return nil }
        if repeatMode == .one && !userInitiated { return i }
        if i + 1 < items.count { return i + 1 }
        return repeatMode == .off ? nil : 0
    }

    /// Advances; returns the new current item, or nil at the end of the queue (playback should stop).
    @discardableResult
    public mutating func advance(userInitiated: Bool) -> QueueItem? {
        guard let n = nextIndex(userInitiated: userInitiated) else { return nil }
        currentIndex = n
        return current
    }

    public enum PreviousAction: Equatable { case restartCurrent, moveTo(Int) }

    /// Standard player behaviour: after 3 s "previous" restarts the track, otherwise goes back.
    public func previousAction(position: TimeInterval) -> PreviousAction {
        guard let i = currentIndex else { return .restartCurrent }
        if position > 3 { return .restartCurrent }
        if i > 0 { return .moveTo(i - 1) }
        if repeatMode == .all, items.count > 1 { return .moveTo(items.count - 1) }
        return .restartCurrent
    }

    @discardableResult
    public mutating func goBack(position: TimeInterval) -> PreviousAction {
        let action = previousAction(position: position)
        if case .moveTo(let i) = action { currentIndex = i }
        return action
    }

    public mutating func jump(to index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    public mutating func jump(toItemId id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) { currentIndex = i }
    }

    public mutating func playNext(_ tracks: [Track]) {
        let entries = tracks.map { QueueItem(track: $0) }
        let at = (currentIndex ?? -1) + 1
        items.insert(contentsOf: entries, at: at)
        insertIntoUnshuffled(entries, after: current)
        if currentIndex == nil, !items.isEmpty { currentIndex = 0 }
    }

    public mutating func append(_ tracks: [Track]) {
        let entries = tracks.map { QueueItem(track: $0) }
        items.append(contentsOf: entries)
        unshuffled.append(contentsOf: entries)
        if currentIndex == nil, !items.isEmpty { currentIndex = 0 }
    }

    private mutating func insertIntoUnshuffled(_ entries: [QueueItem], after: QueueItem?) {
        if let after, let i = unshuffled.firstIndex(where: { $0.id == after.id }) {
            unshuffled.insert(contentsOf: entries, at: i + 1)
        } else {
            unshuffled.insert(contentsOf: entries, at: 0)
        }
    }

    /// Removes an entry. Removing the current entry makes the following one current.
    public mutating func remove(itemId: String) {
        guard let i = items.firstIndex(where: { $0.id == itemId }) else { return }
        items.remove(at: i)
        unshuffled.removeAll { $0.id == itemId }
        guard let c = currentIndex else { return }
        if items.isEmpty { currentIndex = nil }
        else if i < c { currentIndex = c - 1 }
        else if i == c { currentIndex = min(c, items.count - 1) }
    }

    /// Moves an upcoming entry; indices are absolute queue positions.
    public mutating func move(from: Int, to: Int) {
        guard items.indices.contains(from), to >= 0, to < items.count, from != to else { return }
        let currentId = current?.id
        let item = items.remove(at: from)
        items.insert(item, at: to)
        if let currentId { currentIndex = items.firstIndex { $0.id == currentId } }
    }

    public mutating func clearUpNext() {
        guard let i = currentIndex else { return }
        let removed = Set(items[(i + 1)...].map(\.id))
        items.removeSubrange((i + 1)...)
        unshuffled.removeAll { removed.contains($0.id) }
    }

    /// Updates track metadata (e.g. like state) for every entry of that track.
    public mutating func updateTrack(_ track: Track) {
        for i in items.indices where items[i].track.id == track.id { items[i].track = track }
        for i in unshuffled.indices where unshuffled[i].track.id == track.id { unshuffled[i].track = track }
    }
}

/// Persisted (on disk and on the server) so the queue and position survive relaunch and follow the user.
public struct PlaybackSnapshot: Codable, Sendable, Equatable {
    public var queue: PlaybackQueue
    public var positionMs: Int
    public var savedAt: Date
    public var playbackRate: Double

    public init(queue: PlaybackQueue, positionMs: Int, savedAt: Date = Date(), playbackRate: Double = 1) {
        self.queue = queue; self.positionMs = positionMs; self.savedAt = savedAt; self.playbackRate = playbackRate
    }
}
