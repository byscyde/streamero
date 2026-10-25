import Foundation
import Observation
import StreameroCore
import SwiftUI
import UIKit

/// Remote appearance & feature configuration (`GET /v1/app/config`).
///
/// Loaded from the on-disk cache synchronously at launch (so even the welcome screen uses the last known
/// texts and colours offline), refreshed from the server at launch and whenever `/v1/sync/state` reports a
/// new `configVersion`. `Theme` reads its tokens from `AppearanceStore.shared`; because the store is
/// `@Observable`, every view that used a token re-renders when an admin changes the config.
///
/// Reads happen in view bodies (main thread) and all writes go through `@MainActor` methods, so the
/// unchecked Sendable conformance only exists to allow the nonisolated `Theme` accessors.
@Observable
final class AppearanceStore: @unchecked Sendable {
    static let shared = AppearanceStore()
    static let cacheName = "app-config"

    private(set) var config: AppConfig
    private(set) var palette: ResolvedPalette

    /// Notified after a new config was applied (AppModel forwards feature switches to the player).
    @ObservationIgnored var onChange: ((AppConfig) -> Void)?
    @ObservationIgnored private var fetching = false

    init(config: AppConfig? = nil) {
        let initial = config ?? JSONFileStore.load(AppConfig.self, from: AppearanceStore.cacheName) ?? .defaults
        self.config = initial
        self.palette = ResolvedPalette(initial.theme)
    }

    var features: AppConfig.Features { config.features }
    var brand: AppConfig.Brand { config.brand }

    @MainActor
    func apply(_ new: AppConfig, persist: Bool = true) {
        guard new != config else { return }
        config = new
        palette = ResolvedPalette(new.theme)
        if persist { JSONFileStore.save(new, to: AppearanceStore.cacheName) }
        onChange?(new)
    }

    /// Fetches the public config (no sign-in needed). Failures keep the cached document.
    @MainActor
    func refresh(api: APIClient?) async {
        guard let api, !fetching else { return }
        fetching = true
        defer { fetching = false }
        if let fresh = try? await api.appConfig() { apply(fresh) }
    }

    /// Called by SyncCenter after every poll.
    @MainActor
    func syncReported(configVersion: String?, api: APIClient?) async {
        guard AppConfig.needsRefetch(cachedVersion: config.version, serverVersion: configVersion) else { return }
        await refresh(api: api)
    }

    /// Back to the built-in defaults (used by UI tests' reset).
    @MainActor
    func resetToDefaults() {
        JSONFileStore.remove(AppearanceStore.cacheName)
        apply(.defaults, persist: false)
    }
}

/// Theme colours resolved from the config's `#RRGGBB` strings. Dark values come from the config;
/// the light appearance (Settings → Theme) keeps the configured accent on a light canvas.
struct ResolvedPalette {
    var background: Color
    var surface: Color
    var surfaceRaised: Color
    var surfaceHighlight: Color
    var border: Color
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var accent: Color
    var onAccent: Color
    var accentUIColor: UIColor
    var backgroundUIColor: UIColor
    var surfaceUIColor: UIColor

    init(_ theme: AppConfig.Theme) {
        let d = AppConfig.defaults.theme
        func hex(_ s: String, _ fallback: String) -> UInt32 { (HexColor(s) ?? HexColor(fallback))?.rgb ?? 0 }
        let bg = hex(theme.background, d.background)
        let surface = hex(theme.surface, d.surface)
        let raised = hex(theme.surfaceRaised, d.surfaceRaised)
        let border = hex(theme.border, d.border)
        let text = hex(theme.textPrimary, d.textPrimary)
        let text2 = hex(theme.textSecondary, d.textSecondary)
        let accent = hex(theme.accent, d.accent)
        let onAccent = hex(theme.onAccent, d.onAccent)

        self.background = ResolvedPalette.dynamic(dark: bg, light: 0xFFFFFF)
        self.surface = ResolvedPalette.dynamic(dark: surface, light: 0xF4F4F5)
        self.surfaceRaised = ResolvedPalette.dynamic(dark: raised, light: 0xE9E9EC)
        self.surfaceHighlight = ResolvedPalette.dynamic(dark: ResolvedPalette.mix(raised, 0xFFFFFF, 0.06), light: 0xDEDEE3)
        self.border = ResolvedPalette.dynamic(dark: border, light: 0xD4D4D8)
        self.textPrimary = ResolvedPalette.dynamic(dark: text, light: 0x0E0E10)
        self.textSecondary = ResolvedPalette.dynamic(dark: text2, light: 0x5F5F66)
        self.textTertiary = ResolvedPalette.dynamic(dark: ResolvedPalette.mix(text2, bg, 0.4), light: 0x9A9AA2)
        self.accent = Color(hex: accent)
        self.onAccent = Color(hex: onAccent)
        self.accentUIColor = UIColor(hex: accent)
        self.backgroundUIColor = ResolvedPalette.dynamicUI(dark: bg, light: 0xFFFFFF)
        self.surfaceUIColor = ResolvedPalette.dynamicUI(dark: surface, light: 0xF4F4F5)
    }

    static func dynamicUI(dark: UInt32, light: UInt32) -> UIColor {
        let darkColor = UIColor(hex: dark)
        let lightColor = UIColor(hex: light)
        return UIColor { traits in traits.userInterfaceStyle == .light ? lightColor : darkColor }
    }

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: dynamicUI(dark: dark, light: light))
    }

    /// Linear blend of two RGB values: `t` = 0 → a, 1 → b.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) }
        func blend(_ shift: UInt32) -> UInt32 {
            UInt32(max(0, min(255, (ch(a, shift) * (1 - t) + ch(b, shift) * t).rounded()))) << shift
        }
        return blend(16) | blend(8) | blend(0)
    }
}
