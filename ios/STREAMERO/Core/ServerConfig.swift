import Foundation

/// The app always talks to the STREAMERO service. The address is fixed at build time
/// (`STREAMERO_SERVER_URL` in project.yml, default https://app.streamero.net) and never shown to users.
enum ServerConfig {
    static let fallback = URL(string: "https://app.streamero.net")!

    static var url: URL { resolve(Bundle.main.object(forInfoDictionaryKey: "StreameroServerURL")) }

    /// Only an absolute https URL is accepted; anything else (missing, unexpanded build setting, http) falls back.
    static func resolve(_ value: Any?) -> URL {
        guard let s = value as? String,
              let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme == "https", u.host != nil else {
            return fallback
        }
        return u
    }
}
