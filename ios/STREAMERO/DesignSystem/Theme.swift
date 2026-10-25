import StreameroCore
import SwiftUI
import UIKit

/// STREAMERO design tokens. Views use these semantic names only, never raw colours or magic numbers.
///
/// The look: near-black canvas, one red accent, white type, monospace titles for music, outline pills.
/// Colours, the title font, the corner radius and genre gradients come from the remote appearance
/// config (`AppearanceStore`), so every token is a computed property that SwiftUI observes.
enum Theme {
    // MARK: Colour

    enum Palette {
        static var background: Color { AppearanceStore.shared.palette.background }
        static var surface: Color { AppearanceStore.shared.palette.surface }
        static var surfaceRaised: Color { AppearanceStore.shared.palette.surfaceRaised }
        static var surfaceHighlight: Color { AppearanceStore.shared.palette.surfaceHighlight }
        /// Compact tiles (shortcuts) sit on the card surface.
        static var tile: Color { AppearanceStore.shared.palette.surface }
        /// Outline pills ("More", Shuffle, Radio) and hairlines.
        static var border: Color { AppearanceStore.shared.palette.border }
        static var separator: Color { AppearanceStore.shared.palette.border.opacity(0.6) }
        static var textPrimary: Color { AppearanceStore.shared.palette.textPrimary }
        static var textSecondary: Color { AppearanceStore.shared.palette.textSecondary }
        static var textTertiary: Color { AppearanceStore.shared.palette.textTertiary }
        static var accent: Color { AppearanceStore.shared.palette.accent }
        static var onAccent: Color { AppearanceStore.shared.palette.onAccent }
        static var accentUIColor: UIColor { AppearanceStore.shared.palette.accentUIColor }
        static var backgroundUIColor: UIColor { AppearanceStore.shared.palette.backgroundUIColor }
        static var surfaceUIColor: UIColor { AppearanceStore.shared.palette.surfaceUIColor }
        /// Legacy aliases: the old design had several highlight colours; the new one has a single accent.
        static var violet: Color { accent }
        static var turquoise: Color { accent }
        static var success: Color { accent }
        static let blue = Color(hex: 0x509BF5)
        static let warning = Color(hex: 0xFFA42B)
        static let danger = Color(hex: 0xFF4552)
        static var explicitBadge: Color { textSecondary }
        /// The big round transport button (white with black glyph, independent of the accent).
        static let playButton = Color.white
        static let onPlayButton = Color.black
    }

    enum Gradients {
        /// Accent expressed as a gradient so `foregroundStyle(brand)` call sites stay valid.
        static var brand: LinearGradient {
            LinearGradient(colors: [Color(hex: 0xFF5A64), Palette.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        static var brandHorizontal: LinearGradient {
            LinearGradient(colors: [Color(hex: 0xFF5A64), Palette.accent], startPoint: .leading, endPoint: .trailing)
        }
        /// Liked Songs tile: deep red to near-black.
        static var likedSongs: LinearGradient {
            LinearGradient(colors: [Color(hex: 0xFF4552), Color(hex: 0x8E0F1A), Color(hex: 0x2A0A0E)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        static func artworkWash(_ tint: Color) -> LinearGradient {
            LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.35), Palette.background], startPoint: .top, endPoint: .bottom)
        }
        static let scrim = LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
        static let tabBar = LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)

        /// Colourful genre chip gradients (pairs), picked by a stable hash of the genre name.
        static let genrePairs: [(UInt32, UInt32)] = [
            (0x6A5CFF, 0xF06AD7), // violet → pink ("Pop")
            (0x7A0D16, 0xE31E2D), // wine → red
            (0x0F3D6E, 0x2F8CFF), // navy → blue
            (0xFF7A18, 0xFFC03A), // orange → amber
            (0x5B2A86, 0xB24BF3), // plum → purple
            (0x00897B, 0x35C2B0), // teal
            (0xB0124D, 0xFF5A8A), // raspberry
            (0x1F2A44, 0x5B6B8C), // slate
            (0x9C3D00, 0xFF8A3D), // rust
            (0x3B1F6B, 0x6A8DFF), // indigo
        ]

        static func genre(_ name: String) -> LinearGradient {
            genre(index: stableIndex(name, count: genrePairs.count))
        }

        static func genre(index: Int) -> LinearGradient {
            let pair = genrePairs[abs(index) % genrePairs.count]
            return LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        /// djb2: deterministic between launches (unlike `hashValue`).
        static func stableIndex(_ s: String, count: Int) -> Int {
            let h = s.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
            return Int(h % UInt32(max(1, count)))
        }
    }

    // MARK: Typography (Dynamic Type aware where it matters)

    enum Typography {
        static let display = Font.system(.largeTitle).weight(.heavy)
        static let screenTitle = Font.system(size: 24, weight: .bold)
        static let title = Font.system(.title2).weight(.bold)
        static let headline = Font.system(.headline).weight(.bold)
        static let body = Font.system(.body)
        static let callout = Font.system(.subheadline)
        static let caption = Font.system(.caption)
        static let micro = Font.system(.caption2).weight(.bold)
        static let mono = Font.system(.caption2).monospacedDigit()
        /// Section headers ("Genres", "Top artist", "New albums").
        static let section = Font.system(size: 22, weight: .bold)

        /// Font design for track / album / artist titles (`theme.titleFont`).
        static var titleDesign: Font.Design {
            switch AppearanceStore.shared.config.theme.titleFont {
            case .mono: .monospaced
            case .rounded: .rounded
            case .default: .default
            }
        }

        /// Track, album and artist titles: bold and monospaced by default.
        static func media(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
            Font.system(size: size, weight: weight, design: titleDesign)
        }
    }

    // MARK: Layout

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let screen: CGFloat = 16
    }

    enum Radius {
        static let s: CGFloat = 4
        static let m: CGFloat = 8
        static let l: CGFloat = 10
        static let xl: CGFloat = 16
        /// Cards and large artwork (`theme.cornerRadius`, 0…28).
        static var card: CGFloat { CGFloat(AppearanceStore.shared.config.theme.cornerRadius) }
        /// Small artwork in rows and the mini player.
        static var artwork: CGFloat { min(card, 8) }
    }

    enum Shadow {
        static let artworkColor = Color.black.opacity(0.45)
        static let artworkRadius: CGFloat = 24
        static let cardColor = Color.black.opacity(0.25)
    }

    enum Motion {
        static let quick = Animation.spring(response: 0.25, dampingFraction: 0.9)
        static let standard = Animation.spring(response: 0.4, dampingFraction: 0.85)
        static let expressive = Animation.spring(response: 0.55, dampingFraction: 0.78)
    }

    enum Size {
        static let miniPlayerHeight: CGFloat = 64
        static let rowArtwork: CGFloat = 52
        static let card: CGFloat = 160
        static let bigCard: CGFloat = 196
        static let artistAvatar: CGFloat = 132
        static let minTapTarget: CGFloat = 44
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case dark, light, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// Lightweight haptics vocabulary; respects the system "System Haptics" setting automatically.
@MainActor
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func toggle() { UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.7) }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}
