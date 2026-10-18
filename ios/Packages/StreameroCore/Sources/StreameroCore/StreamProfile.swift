import Foundation

public enum StreamProfile: String, Codable, Sendable, CaseIterable, Identifiable {
    case dataSaver = "data_saver"
    case standard
    case high
    case lossless

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dataSaver: "Data Saver"
        case .standard: "Standard"
        case .high: "High"
        case .lossless: "Lossless"
        }
    }

    public var detail: String {
        switch self {
        case .dataSaver: "AAC up to 96 kbps"
        case .standard: "AAC up to 160 kbps"
        case .high: "AAC up to 256 kbps"
        case .lossless: "ALAC, when the original is lossless"
        }
    }
}

public enum NetworkKind: String, Codable, Sendable { case wifi, cellular, offline }

/// User's quality choices; which one applies depends on the current network.
public struct QualityPolicy: Codable, Sendable, Equatable {
    public var wifi: StreamProfile
    public var cellular: StreamProfile
    public var download: StreamProfile

    public init(wifi: StreamProfile = .high, cellular: StreamProfile = .standard, download: StreamProfile = .high) {
        self.wifi = wifi; self.cellular = cellular; self.download = download
    }

    public func profile(for network: NetworkKind, lowDataMode: Bool = false) -> StreamProfile {
        if lowDataMode { return .dataSaver }
        switch network {
        case .wifi: return wifi
        case .cellular, .offline: return cellular
        }
    }
}

/// Equal-power crossfade gains for `progress` in 0...1, so perceived loudness stays constant.
public func crossfadeGains(progress: Double) -> (outgoing: Float, incoming: Float) {
    let p = min(1, max(0, progress))
    return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
}
