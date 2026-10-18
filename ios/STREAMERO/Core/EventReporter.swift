import Foundation
import StreameroCore

/// Durable outbox for listening events: written to disk first, sent in batches, retried when online.
/// Server-side idempotency (clientEventId) makes re-sending after a crash harmless.
@MainActor
final class EventReporter {
    private var pending: [PlaybackEvent]
    private var api: APIClient?
    private var sending = false

    init() { pending = JSONFileStore.load([PlaybackEvent].self, from: "event-outbox") ?? [] }

    func attach(api: APIClient?) { self.api = api }

    func record(_ event: PlaybackEvent) {
        pending.append(event)
        if pending.count > 2000 { pending.removeFirst(pending.count - 2000) }
        JSONFileStore.save(pending, to: "event-outbox")
        Task { await flush() }
    }

    func flush() async {
        guard let api, !sending, !pending.isEmpty else { return }
        sending = true
        defer { sending = false }
        let batch = Array(pending.prefix(200))
        do {
            try await api.sendPlaybackEvents(batch)
            let sent = Set(batch.map(\.clientEventId))
            pending.removeAll { sent.contains($0.clientEventId) }
            JSONFileStore.save(pending, to: "event-outbox")
            if !pending.isEmpty { Task { await flush() } }
        } catch {}
    }
}

enum DeviceIdentity {
    /// Random per-install identifier (not the vendor id), used to label sessions and queue sync.
    static let id: String = {
        let key = "streamero.deviceId"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }()
}
