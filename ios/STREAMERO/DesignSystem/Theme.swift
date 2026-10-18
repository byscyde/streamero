import SwiftUI
import UIKit

/// STREAMERO design tokens. Views use these semantic names only, never raw colours or magic numbers.
enum Theme {
    // MARK: Colour

    /// Dark-first palette with a light variant. Accents are restrained violet → electric blue → turquoise.
    enum Palette {
        static let background = dynamic(dark: 0x0B0B12, light: 0xF6F6FA)
        static let surface = dynamic(dark: 0x14141D, light: 0xFFFFFF)
        static let surfaceRaised = dynamic(dark: 0x1C1C28, light: 0xEEEEF5)
        static let surfaceHighlight = dynamic(dark: 0x262635, light: 0xE3E3EE)
        static let separator = dynamic(dark: 0x2A2A3A, light: 0xD9D9E3)
        static let textPrimary = dynamic(dark: 0xF4F4F8, light: 0x101018)
        static let textSecondary = dynamic(dark: 0xA3A3B8, light: 0x55556A)
        static let textTertiary = dynamic(dark: 0x6E6E85, light: 0x8A8A9E)
        static let violet = Color(hex: 0x8B5CF6)
        static let blue = Color(hex: 0x3B82F6)
        static let turquoise = Color(hex: 0x2DD4BF)
        static let accent = violet
        static let success = Color(hex: 0x34D399)
        static let warning = Color(hex: 0xFBBF24)
        static let danger = Color(hex: 0xF87171)
        static let explicitBadge = dynamic(dark: 0x3A3A4D, light: 0xD4D4DE)

        static func dynamic(dark: UInt32, light: UInt32) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark) })
        }
    }

    enum Gradients {
        static let brand = LinearGradient(colors: [Palette.violet, Palette.blue, Palette.turquoise], startPoint: .topLeading, endPoint: .bottomTrailing)
        static let brandHorizontal = LinearGradient(colors: [Palette.violet, Palette.blue, Palette.turquoise], startPoint: .leading, endPoint: .trailing)
        static func artworkWash(_ tint: Color) -> LinearGradient {
            LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.15), Palette.background], startPoint: .top, endPoint: .bottom)
        }
        static let scrim = LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
    }

    // MARK: Typography (Dynamic Type aware)

    enum Typography {
        static let display = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let title = Font.system(.title2, design: .rounded).weight(.bold)
        static let headline = Font.system(.headline, design: .rounded)
        static let body = Font.system(.body)
        static let callout = Font.system(.callout)
        static let caption = Font.system(.caption).weight(.medium)
        static let micro = Font.system(.caption2).weight(.semibold)
        static let mono = Font.system(.caption, design: .monospaced).weight(.medium)
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
        static let screen: CGFloat = 20
    }

    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let artwork: CGFloat = 8
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
