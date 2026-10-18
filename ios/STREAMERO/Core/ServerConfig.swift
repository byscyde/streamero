import Foundation

/// The app talks to a self-hosted STREAMERO server; its URL is chosen during onboarding.
enum ServerConfig {
    private static let key = "streamero.serverURL"

    static var bundledDefault: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "StreameroDefaultServerURL") as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    static var current: URL? {
        get { UserDefaults.standard.string(forKey: key).flatMap(URL.init(string:)) ?? bundledDefault }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: key) }
    }

    /// Accepts "music.example.com" or "http://192.168.1.10:8080"; https is assumed when no scheme is given.
    static func normalise(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}
