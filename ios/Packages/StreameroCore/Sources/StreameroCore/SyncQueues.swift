import Foundation

public enum LibraryItemType: String, Codable, Sendable { case track, album, artist, video, playlist }

public struct LibraryChange: Codable, Sendable, Equatable {
    public var type: LibraryItemType
    public var id: String
    public var op: Op
    public var at: Date
    public enum Op: String, Codable, Sendable { case add, remove }

    public init(type: LibraryItemType, id: String, op: Op, at: Date = Date()) {
        self.type = type; self.id = id; self.op = op; self.at = at
    }
}

/// Offline-first library edits: changes are applied locally at once and queued for the server.
/// Only the latest change per item matters, so the queue coalesces (like→unlike→like = one "add").
public struct LibraryChangeQueue: Codable, Sendable, Equatable {
    public private(set) var pending: [LibraryChange] = []
    public init() {}

    public mutating func record(_ change: LibraryChange) {
        pending.removeAll { $0.type == change.type && $0.id == change.id }
        pending.append(change)
    }

    /// Drops changes the server acknowledged (matched by item and timestamp, so newer edits survive).
    public mutating func acknowledge(_ sent: [LibraryChange]) {
        pending.removeAll { p in sent.contains { $0.type == p.type && $0.id == p.id && $0.at == p.at } }
    }

    public func batch(max: Int = 500) -> [LibraryChange] { Array(pending.prefix(max)) }

    /// Effective local state overlay: what the UI should show before the server confirms.
    public func overlay(type: LibraryItemType, id: String, serverValue: Bool) -> Bool {
        guard let last = pending.last(where: { $0.type == type && $0.id == id }) else { return serverValue }
        return last.op == .add
    }
}

public struct PlaybackEvent: Codable, Sendable, Equatable, Identifiable {
    public var clientEventId: String
    public var trackId: String?
    public var videoId: String?
    public var playedAt: Date
    public var durationPlayedMs: Int
    public var completed: Bool
    public var contextType: String?
    public var contextId: String?
    public var deviceId: String?
    public var id: String { clientEventId }

    public init(clientEventId: String = UUID().uuidString, trackId: String? = nil, videoId: String? = nil, playedAt: Date, durationPlayedMs: Int,
                completed: Bool, contextType: String? = nil, contextId: String? = nil, deviceId: String? = nil) {
        self.clientEventId = clientEventId; self.trackId = trackId; self.videoId = videoId; self.playedAt = playedAt
        self.durationPlayedMs = durationPlayedMs; self.completed = completed; self.contextType = contextType
        self.contextId = contextId; self.deviceId = deviceId
    }
}

/// Measures actual listening time of the current item (pauses and seeks excluded) and emits an event.
public struct ListeningSession: Sendable, Equatable {
    public let trackId: String
    public let startedAt: Date
    public let context: PlaybackContext?
    private(set) var accumulated: TimeInterval = 0
    private var runningSince: Date?

    public init(trackId: String, startedAt: Date = Date(), context: PlaybackContext?) {
        self.trackId = trackId; self.startedAt = startedAt; self.context = context
    }

    public mutating func resume(at date: Date = Date()) { if runningSince == nil { runningSince = date } }
    public mutating func pause(at date: Date = Date()) {
        if let s = runningSince { accumulated += max(0, date.timeIntervalSince(s)); runningSince = nil }
    }

    public func listened(at date: Date = Date()) -> TimeInterval {
        accumulated + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    /// Returns nil for plays shorter than one second (accidental taps) to keep history clean.
    public func finish(completed: Bool, deviceId: String?, at date: Date = Date()) -> PlaybackEvent? {
        let ms = Int(listened(at: date) * 1000)
        guard ms >= 1000 || completed else { return nil }
        let isVideoAudio = context?.type == "video"
        return PlaybackEvent(trackId: isVideoAudio ? nil : trackId, videoId: isVideoAudio ? context?.id : nil, playedAt: startedAt,
                             durationPlayedMs: ms, completed: completed,
                             contextType: isVideoAudio ? nil : context?.type, contextId: isVideoAudio ? nil : context?.id.flatMap { UUID(uuidString: $0) != nil ? $0 : nil },
                             deviceId: deviceId)
    }
}
