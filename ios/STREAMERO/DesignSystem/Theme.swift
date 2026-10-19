import SwiftUI
import UIKit

/// STREAMERO design tokens. Views use these semantic names only, never raw colours or magic numbers.
enum Theme {
    // MARK: Colour

    /// Streaming-app dark palette: near-black canvas, grey elevation steps, white type, one green accent.
    /// The accent is a single token, so the brand colour can be changed in one place.
    enum Palette {
        static let background = dynamic(dark: 0x121212, light: 0xFFFFFF)
        static let surface = dynamic(dark: 0x181818, light: 0xF6F6F6)
        static let surfaceRaised = dynamic(dark: 0x242424, light: 0xEDEDED)
        static let surfaceHighlight = dynamic(dark: 0x2A2A2A, light: 0xE2E2E2)
        static let tile = dynamic(dark: 0x2A2A2A, light: 0xEFEFEF)
        static let separator = dynamic(dark: 0x2A2A2A, light: 0xDADADA)
        static let textPrimary = dynamic(dark: 0xFFFFFF, light: 0x000000)
        static let textSecondary = dynamic(dark: 0xB3B3B3, light: 0x6A6A6A)
        static let textTertiary = dynamic(dark: 0x727272, light: 0x9A9A9A)
        static let accent = Color(hex: 0x1FDF64)
        static let onAccent = Color.black
        static let violet = accent
        static let blue = Color(hex: 0x509BF5)
        static let turquoise = accent
        static let success = accent
        static let warning = Color(hex: 0xFFA42B)
        static let danger = Color(hex: 0xF15E6C)
        static let explicitBadge = dynamic(dark: 0xB3B3B3, light: 0x6A6A6A)

        static func dynamic(dark: UInt32, light: UInt32) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark) })
        }
    }

    enum Gradients {
        /// Solid accent expressed as a gradient so existing `foregroundStyle(brand)` call sites stay valid.
        static let brand = LinearGradient(colors: [Palette.accent, Palette.accent], startPoint: .top, endPoint: .bottom)
        static let brandHorizontal = brand
        /// Liked Songs tile.
        static let likedSongs = LinearGradient(colors: [Color(hex: 0x450AF5), Color(hex: 0x8E8EE5), Color(hex: 0xC4EFD9)], startPoint: .topLeading, endPoint: .bottomTrailing)
        static func artworkWash(_ tint: Color) -> LinearGradient {
            LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.35), Palette.background], startPoint: .top, endPoint: .bottom)
        }
        static let scrim = LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
        static let tabBar = LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)
    }

    // MARK: Typography (Dynamic Type aware)

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
        static let m: CGFloat = 6
        static let l: CGFloat = 8
        static let xl: CGFloat = 12
        static let artwork: CGFloat = 4
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
        static let miniPlayerHeight: CGFloat = 56
        static let rowArtwork: CGFloat = 48
        static let card: CGFloat = 150
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
