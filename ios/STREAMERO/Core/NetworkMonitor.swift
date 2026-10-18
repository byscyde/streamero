import Network
import Observation
import StreameroCore

@MainActor
@Observable
final class NetworkMonitor {
    private(set) var kind: NetworkKind = .wifi
    private(set) var isConstrained = false
    private(set) var isExpensive = false
    var isOnline: Bool { kind != .offline }

    private let monitor = NWPathMonitor()
    /// Called when connectivity returns, to flush offline queues.
    var onReconnect: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.update(path) }
        }
        monitor.start(queue: DispatchQueue(label: "streamero.network"))
    }

    private func update(_ path: NWPath) {
        let wasOffline = kind == .offline
        if path.status != .satisfied { kind = .offline }
        else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) { kind = .wifi }
        else { kind = .cellular }
        isConstrained = path.isConstrained
        isExpensive = path.isExpensive
        if wasOffline && kind != .offline { onReconnect?() }
    }
}
