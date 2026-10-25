import Foundation
import Observation
import StreameroCore

/// Playback, download, subtitle and appearance preferences. Stored locally and synced to the
/// account (`/v1/me/preferences`) with version checks so the newest device wins cleanly.
@MainActor
@Observable
final class SettingsStore {
    struct Values: Codable, Equatable {
        var quality = QualityPolicy()
        var crossfadeSeconds: Double = 0
        var gapless = true
        var downloadOverCellular = false
        var subtitlesEnabled = false
        var subtitleLanguages: [String] = Locale.preferredLanguages.map { String($0.prefix(2)) }
        var subtitleScale: Double = 1
        var subtitleBackground = true
        var preferNativeSubtitles = false
        var appearance: AppearanceMode = .dark
        var autoplayVideos = true
        var showLyricsByDefault = false
        /// 10-band music equaliser (applied live by AudioPlayer).
        var equalizer = EqualizerSettings()

        enum CodingKeys: String, CodingKey {
            case quality, crossfadeSeconds, gapless, downloadOverCellular, subtitlesEnabled, subtitleLanguages, subtitleScale
            case subtitleBackground, preferNativeSubtitles, appearance, autoplayVideos, showLyricsByDefault, equalizer
        }
    }

    var values: Values {
        didSet {
            guard values != oldValue else { return }
            persist()
            scheduleSync()
            if values.equalizer != oldValue.equalizer { onEqualizerChange?(values.equalizer) }
        }
    }
    /// AudioPlayer listens so EQ edits (local or adopted from another device) apply immediately.
    @ObservationIgnored var onEqualizerChange: ((EqualizerSettings) -> Void)?
    private(set) var serverVersion = 0
    private var api: APIClient?
    private var syncTask: Task<Void, Never>?

    init() {
        values = JSONFileStore.load(Values.self, from: "settings") ?? Values()
        serverVersion = UserDefaults.standard.integer(forKey: "streamero.preferencesVersion")
    }

    func attach(api: APIClient?) { self.api = api }

    private func persist() { JSONFileStore.save(values, to: "settings") }

    /// Adopts server preferences when they are newer than what this device last synced.
    func adopt(server prefs: JSONValue?, version: Int?) {
        guard let version, version > serverVersion, let prefs, case .object(let o) = prefs, !o.isEmpty,
              let data = try? JSONEncoder().encode(prefs), let decoded = try? JSONDecoder().decode(Values.self, from: data) else { return }
        serverVersion = version
        UserDefaults.standard.set(version, forKey: "streamero.preferencesVersion")
        if decoded != values { values = decoded; syncTask?.cancel() }
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.pushToServer()
        }
    }

    private func pushToServer() async {
        guard let api, let data = try? JSONEncoder().encode(values), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        do {
            let res = try await api.putPreferences(json, baseVersion: serverVersion)
            if let v = res["version"]?.doubleValue { serverVersion = Int(v); UserDefaults.standard.set(serverVersion, forKey: "streamero.preferencesVersion") }
        } catch let e as APIError where e.code == "version_conflict" {
            // Another device changed settings: adopt theirs (server is the tie-breaker).
            if case .server(_, _, _, let details) = e { adopt(server: details?["preferences"], version: details?["version"]?.doubleValue.map(Int.init)) }
        } catch {}
    }
}

/// Lenient decoding: fields added in later versions (e.g. `equalizer`) fall back to their defaults
/// instead of failing the whole document, so upgrading never resets a user's settings.
extension SettingsStore.Values {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? current }
        quality = get(.quality, quality)
        crossfadeSeconds = get(.crossfadeSeconds, crossfadeSeconds)
        gapless = get(.gapless, gapless)
        downloadOverCellular = get(.downloadOverCellular, downloadOverCellular)
        subtitlesEnabled = get(.subtitlesEnabled, subtitlesEnabled)
        subtitleLanguages = get(.subtitleLanguages, subtitleLanguages)
        subtitleScale = get(.subtitleScale, subtitleScale)
        subtitleBackground = get(.subtitleBackground, subtitleBackground)
        preferNativeSubtitles = get(.preferNativeSubtitles, preferNativeSubtitles)
        appearance = get(.appearance, appearance)
        autoplayVideos = get(.autoplayVideos, autoplayVideos)
        showLyricsByDefault = get(.showLyricsByDefault, showLyricsByDefault)
        equalizer = get(.equalizer, equalizer)
    }
}
