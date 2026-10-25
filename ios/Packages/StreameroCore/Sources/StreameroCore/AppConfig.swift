import Foundation

/// Remote appearance / feature configuration (`GET /v1/app/config`, see docs/APP_CONFIG.md §1).
///
/// The server always returns the full document merged over the defaults, but the client is lenient as
/// well: every missing (or malformed) field falls back to `AppConfig.defaults`, so an older or partial
/// document never breaks the app.
public struct AppConfig: Codable, Sendable, Equatable {
    public var version: String
    public var brand: Brand
    public var theme: Theme
    public var texts: Texts
    public var home: Home
    public var features: Features
    public var announcement: Announcement

    public init(version: String = "", brand: Brand = Brand(), theme: Theme = Theme(), texts: Texts = Texts(),
                home: Home = Home(), features: Features = Features(), announcement: Announcement = Announcement()) {
        self.version = version; self.brand = brand; self.theme = theme; self.texts = texts
        self.home = home; self.features = features; self.announcement = announcement
    }

    /// The built-in document (identical to the defaults in docs/APP_CONFIG.md).
    public static let defaults = AppConfig()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.defaults
        version = c.lenient(String.self, .version) ?? d.version
        brand = c.lenient(Brand.self, .brand) ?? d.brand
        theme = c.lenient(Theme.self, .theme) ?? d.theme
        texts = c.lenient(Texts.self, .texts) ?? d.texts
        home = c.lenient(Home.self, .home) ?? d.home
        features = c.lenient(Features.self, .features) ?? d.features
        announcement = c.lenient(Announcement.self, .announcement) ?? d.announcement
    }

    // MARK: Sections

    public struct Brand: Codable, Sendable, Equatable {
        public var appName: String
        public var tagline: String
        public var developer: String
        public var developerUrl: String
        public var supportEmail: String

        public init(appName: String = "STREAMERO", tagline: String = "Your Sound. Your Screen. Your World.", developer: String = "SCYDE",
                    developerUrl: String = "https://scyde.dev", supportEmail: String = "no-reply@scyde.dev") {
            self.appName = appName; self.tagline = tagline; self.developer = developer; self.developerUrl = developerUrl; self.supportEmail = supportEmail
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Brand()
            appName = c.lenient(String.self, .appName) ?? d.appName
            tagline = c.lenient(String.self, .tagline) ?? d.tagline
            developer = c.lenient(String.self, .developer) ?? d.developer
            developerUrl = c.lenient(String.self, .developerUrl) ?? d.developerUrl
            supportEmail = c.lenient(String.self, .supportEmail) ?? d.supportEmail
        }
    }

    public enum TitleFont: String, Codable, Sendable, CaseIterable {
        case mono, `default`, rounded
    }

    public enum PlayerStyle: String, Codable, Sendable, CaseIterable {
        case artwork, solid
    }

    public struct Theme: Codable, Sendable, Equatable {
        public var accent: String
        public var onAccent: String
        public var background: String
        public var surface: String
        public var surfaceRaised: String
        public var border: String
        public var textPrimary: String
        public var textSecondary: String
        public var titleFont: TitleFont
        public var cornerRadius: Double
        public var genreGradients: Bool
        public var playerStyle: PlayerStyle

        public init(accent: String = "#E31E2D", onAccent: String = "#FFFFFF", background: String = "#0E0E10", surface: String = "#18181B",
                    surfaceRaised: String = "#232327", border: String = "#3A3A40", textPrimary: String = "#FFFFFF", textSecondary: String = "#A1A1AA",
                    titleFont: TitleFont = .mono, cornerRadius: Double = 12, genreGradients: Bool = true, playerStyle: PlayerStyle = .artwork) {
            self.accent = accent; self.onAccent = onAccent; self.background = background; self.surface = surface
            self.surfaceRaised = surfaceRaised; self.border = border; self.textPrimary = textPrimary; self.textSecondary = textSecondary
            self.titleFont = titleFont; self.cornerRadius = cornerRadius; self.genreGradients = genreGradients; self.playerStyle = playerStyle
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Theme()
            // Colours must be valid #RRGGBB; anything else keeps the default so the UI never turns unreadable.
            func colour(_ key: CodingKeys, _ fallback: String) -> String {
                guard let s = c.lenient(String.self, key), HexColor(s) != nil else { return fallback }
                return s
            }
            accent = colour(.accent, d.accent)
            onAccent = colour(.onAccent, d.onAccent)
            background = colour(.background, d.background)
            surface = colour(.surface, d.surface)
            surfaceRaised = colour(.surfaceRaised, d.surfaceRaised)
            border = colour(.border, d.border)
            textPrimary = colour(.textPrimary, d.textPrimary)
            textSecondary = colour(.textSecondary, d.textSecondary)
            titleFont = c.lenient(String.self, .titleFont).flatMap(TitleFont.init(rawValue:)) ?? d.titleFont
            cornerRadius = min(28, max(0, c.lenient(Double.self, .cornerRadius) ?? d.cornerRadius))
            genreGradients = c.lenient(Bool.self, .genreGradients) ?? d.genreGradients
            playerStyle = c.lenient(String.self, .playerStyle).flatMap(PlayerStyle.init(rawValue:)) ?? d.playerStyle
        }
    }

    public struct Texts: Codable, Sendable, Equatable {
        public var welcomeTitle: String
        public var welcomeSubtitle: String
        public var homeGreeting: Bool

        public init(welcomeTitle: String = "Discover your music,\npersonalize your experience",
                    welcomeSubtitle: String = "Use your email or Apple ID to continue with STREAMERO.", homeGreeting: Bool = true) {
            self.welcomeTitle = welcomeTitle; self.welcomeSubtitle = welcomeSubtitle; self.homeGreeting = homeGreeting
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Texts()
            welcomeTitle = c.lenient(String.self, .welcomeTitle) ?? d.welcomeTitle
            welcomeSubtitle = c.lenient(String.self, .welcomeSubtitle) ?? d.welcomeSubtitle
            homeGreeting = c.lenient(Bool.self, .homeGreeting) ?? d.homeGreeting
        }
    }

    public struct Home: Codable, Sendable, Equatable {
        public static let knownChips = ["All", "Music", "Videos"]
        public static let knownSections = ["recommended_playlists", "genres", "top_artists", "new_albums", "popular_singles",
                                           "recently_played", "made_for_you", "music_videos"]

        public var chips: [String]
        public var sectionsOrder: [String]

        public init(chips: [String] = Home.knownChips, sectionsOrder: [String] = Home.knownSections) {
            self.chips = chips; self.sectionsOrder = sectionsOrder
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Home()
            chips = c.lenient([String].self, .chips) ?? d.chips
            sectionsOrder = c.lenient([String].self, .sectionsOrder) ?? d.sectionsOrder
        }
    }

    public struct Features: Codable, Sendable, Equatable {
        public var videos: Bool
        public var youtube: Bool
        public var lyrics: Bool
        public var downloads: Bool
        public var equalizer: Bool
        public var radio: Bool
        public var signup: Bool
        public var appleSignIn: Bool

        public init(videos: Bool = true, youtube: Bool = true, lyrics: Bool = true, downloads: Bool = true,
                    equalizer: Bool = true, radio: Bool = true, signup: Bool = true, appleSignIn: Bool = true) {
            self.videos = videos; self.youtube = youtube; self.lyrics = lyrics; self.downloads = downloads
            self.equalizer = equalizer; self.radio = radio; self.signup = signup; self.appleSignIn = appleSignIn
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Features()
            videos = c.lenient(Bool.self, .videos) ?? d.videos
            youtube = c.lenient(Bool.self, .youtube) ?? d.youtube
            lyrics = c.lenient(Bool.self, .lyrics) ?? d.lyrics
            downloads = c.lenient(Bool.self, .downloads) ?? d.downloads
            equalizer = c.lenient(Bool.self, .equalizer) ?? d.equalizer
            radio = c.lenient(Bool.self, .radio) ?? d.radio
            signup = c.lenient(Bool.self, .signup) ?? d.signup
            appleSignIn = c.lenient(Bool.self, .appleSignIn) ?? d.appleSignIn
        }
    }

    public enum AnnouncementStyle: String, Codable, Sendable, CaseIterable {
        case info, warning, success
    }

    public struct Announcement: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var text: String
        public var style: AnnouncementStyle

        public init(enabled: Bool = false, text: String = "", style: AnnouncementStyle = .info) {
            self.enabled = enabled; self.text = text; self.style = style
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Announcement()
            enabled = c.lenient(Bool.self, .enabled) ?? d.enabled
            text = c.lenient(String.self, .text) ?? d.text
            style = c.lenient(String.self, .style).flatMap(AnnouncementStyle.init(rawValue:)) ?? d.style
        }

        /// Only shown when switched on and there is something to say.
        public var isVisible: Bool { enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

// MARK: - Derived values

public extension AppConfig {
    /// Home filter chips in the configured order, limited to known values and to enabled features.
    var visibleHomeChips: [String] {
        var seen = Set<String>()
        let chips = home.chips.filter { chip in
            guard Home.knownChips.contains(chip), seen.insert(chip).inserted else { return false }
            return chip != "Videos" || features.videos
        }
        return chips.isEmpty ? ["All"] : chips
    }

    /// `true` when the server reports a config version different from the one this client has (or caches none).
    static func needsRefetch(cachedVersion: String?, serverVersion: String?) -> Bool {
        guard let serverVersion, !serverVersion.isEmpty else { return false }
        return cachedVersion != serverVersion
    }
}

/// Maps backend home section kinds onto the configurable section ids and orders sections accordingly.
public enum HomeSectionOrdering {
    /// Configurable id → backend `HomeSection.kind` values it covers.
    public static let aliases: [String: [String]] = [
        "recommended_playlists": ["recommended_playlists", "featured_playlists", "editorial"],
        "genres": ["genres", "moods"],
        "top_artists": ["top_artists", "favorite_artists"],
        "new_albums": ["new_albums", "recently_added", "album_recommendations"],
        "popular_singles": ["popular_singles", "trending"],
        "recently_played": ["recently_played", "continue_listening"],
        "made_for_you": ["made_for_you"],
        "music_videos": ["music_videos", "continue_watching"],
    ]

    /// The configurable id for a backend kind (nil when the kind is not covered by any id).
    public static func configId(forKind kind: String) -> String? {
        if aliases[kind] != nil { return kind }
        return aliases.first { $0.value.contains(kind) }?.key
    }

    /// Returns the indices of `kinds` in display order: sections named in `order` first (in that order,
    /// keeping the server's order between sections of the same id), then all remaining sections in
    /// server order. Sections whose id is hidden (`hidden`) are dropped.
    public static func order(kinds: [String], by order: [String], hidden: Set<String> = []) -> [Int] {
        var rank: [String: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }
        let visible = kinds.indices.filter { i in
            let id = configId(forKind: kinds[i]) ?? kinds[i]
            return !hidden.contains(id) && !hidden.contains(kinds[i])
        }
        return visible.sorted { a, b in
            let ra = configId(forKind: kinds[a]).flatMap { rank[$0] } ?? Int.max
            let rb = configId(forKind: kinds[b]).flatMap { rank[$0] } ?? Int.max
            return ra == rb ? a < b : ra < rb
        }
    }
}

/// `#RRGGBB` / `RRGGBB` / `#RGB` colour parsing shared by every client surface.
public struct HexColor: Sendable, Equatable, Hashable {
    public var rgb: UInt32

    public init(rgb: UInt32) { self.rgb = rgb & 0xFFFFFF }

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 3, s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let v = UInt32(s, radix: 16) else { return nil }
        rgb = v
    }

    public var red: Double { Double((rgb >> 16) & 0xFF) / 255 }
    public var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(rgb & 0xFF) / 255 }

    /// Canonical upper-case `#RRGGBB`.
    public var hexString: String {
        let digits = String(rgb, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    /// WCAG relative luminance (0 black … 1 white), used to pick legible text on a colour.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value if present and well-formed; `nil` (never an error) otherwise.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
