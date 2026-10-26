import StreameroCore
import SwiftUI

// MARK: - Artwork

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = Theme.Radius.artwork
    var placeholderSymbol = "music.note"
    var circular = false

    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                Theme.Palette.surfaceRaised
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .task(id: url) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let resolved = artworkURL(url, points: size) else { image = nil; return }
        let px = size * scale
        if let cached = ImagePipeline.shared.cached(resolved, pixelSize: px) { image = cached; return }
        let loaded = await ImagePipeline.shared.image(for: resolved, pixelSize: px)
        withAnimation(.easeOut(duration: 0.2)) { image = loaded }
    }
}

/// Fluid-width artwork (fills its container, square).
struct FlexibleArtwork: View {
    let url: URL?
    var cornerRadius: CGFloat = Theme.Radius.card
    var symbol = "music.note"
    var body: some View {
        GeometryReader { geo in
            ArtworkView(url: url, size: geo.size.width, cornerRadius: cornerRadius, placeholderSymbol: symbol)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// 2x2 mosaic for playlists without custom artwork.
struct MosaicArtwork: View {
    let urls: [URL]
    let size: CGFloat
    var cornerRadius: CGFloat = Theme.Radius.artwork
    var body: some View {
        if urls.count >= 4 {
            let half = size / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) { ArtworkView(url: urls[0], size: half, cornerRadius: 0); ArtworkView(url: urls[1], size: half, cornerRadius: 0) }
                HStack(spacing: 0) { ArtworkView(url: urls[2], size: half, cornerRadius: 0); ArtworkView(url: urls[3], size: half, cornerRadius: 0) }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            ArtworkView(url: urls.first, size: size, cornerRadius: cornerRadius, placeholderSymbol: "music.note.list")
        }
    }
}

// MARK: - Buttons

/// Filled accent pill ("Follow", "Next →", "Log in").
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    var height: CGFloat = 52
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(Theme.Palette.accent.opacity(enabled ? 1 : 0.45), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

/// Outlined pill ("Shuffle", "Radio", "Continue with Google").
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var height: CGFloat = 40
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .overlay(Capsule().strokeBorder(Theme.Palette.textPrimary.opacity(0.85), lineWidth: 1.2))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

/// Small grey outline pill used for "More" on section headers.
struct MorePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .overlay(Capsule().strokeBorder(Theme.Palette.border, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// White circular play button with a black glyph (collection headers, release cards, Now Playing).
struct PlayCircleButton: View {
    var isPlaying = false
    var size: CGFloat = 56
    var filledAccent = false
    let action: () -> Void
    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .black))
                .foregroundStyle(filledAccent ? Theme.Palette.onAccent : Theme.Palette.onPlayButton)
                .offset(x: isPlaying ? 0 : size * 0.03)
                .frame(width: size, height: size)
                .background(filledAccent ? Theme.Palette.accent : Theme.Palette.playButton, in: Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

struct IconButton: View {
    let systemName: String
    var label: String
    var size: CGFloat = 22
    var tint: Color = Theme.Palette.textPrimary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(tint)
                .frame(minWidth: Theme.Size.minTapTarget, minHeight: Theme.Size.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Text & badges

/// "Genres ……… (More)": bold section title with an optional outline "More" pill.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var action: (title: String, run: () -> Void)?
    /// Shows the "More" pill linking to this route.
    var more: Route?

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle { Text(subtitle).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary) }
                Text(title).font(Theme.Typography.section).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.s)
            if let more {
                NavigationLink(value: more) { Text("More") }
                    .buttonStyle(MorePillStyle())
                    .accessibilityLabel("More \(title)")
            } else if let action {
                Button(action.title, action: action.run).buttonStyle(MorePillStyle())
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Theme.Palette.background)
            .frame(width: 14, height: 14)
            .background(Theme.Palette.explicitBadge, in: RoundedRectangle(cornerRadius: 2))
            .accessibilityLabel("Explicit")
    }
}

struct QualityBadge: View {
    let text: String
    var lossless = false
    var body: some View {
        Text(text.uppercased())
            .font(Theme.Typography.micro)
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(lossless ? Theme.Palette.accent : Theme.Palette.textSecondary)
            .overlay(Capsule().strokeBorder(lossless ? Theme.Palette.accent : Theme.Palette.border, lineWidth: 1))
    }
}

/// Filter pill (All / Music / Videos, Playlists / Artists / Albums…). Selected = white pill, black text.
struct Chip: View {
    let title: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(title)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 18)
                .frame(height: 36)
                .foregroundStyle(selected ? Color.black : Theme.Palette.textSecondary)
                .background(selected ? Color.white : Theme.Palette.surfaceRaised.opacity(0.0001), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Colourful gradient genre pill (or a plain grey pill when `theme.genreGradients` is off).
struct GenreChip: View {
    let name: String
    var height: CGFloat = 40
    var body: some View {
        let gradients = AppearanceStore.shared.config.theme.genreGradients
        Text(name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background {
                if gradients {
                    Capsule().fill(Theme.Gradients.genre(name))
                } else {
                    Capsule().fill(Theme.Palette.surfaceRaised)
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(gradients ? 0.35 : 0.12), lineWidth: 1))
            .accessibilityLabel(name)
    }
}

/// Circular avatar that opens the profile menu (top-left of the main screens).
struct AvatarButton: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat = 36
    var body: some View {
        Button { withAnimation(Theme.Motion.standard) { app.isMenuOpen = true } } label: {
            AvatarImage(size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile and settings")
    }
}

struct AvatarImage: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().fill(Theme.Gradients.brand)
            Text(String(app.user?.displayName.first ?? "S").uppercased())
                .font(.system(size: size * 0.45, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            if let url = app.avatarURL { ArtworkView(url: url, size: size, circular: true) }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - States

/// Shimmering placeholder used while content loads.
struct Skeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var radius: CGFloat = 6
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.Palette.surfaceRaised)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Theme.Palette.surfaceHighlight.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width)
                    }
                    .clipped()
                }
            }
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
            .accessibilityHidden(true)
    }
}

struct SkeletonRows: View {
    var count = 6
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: Theme.Spacing.m) {
                    Skeleton(width: Theme.Size.rowArtwork, height: Theme.Size.rowArtwork, radius: Theme.Radius.artwork)
                    VStack(alignment: .leading, spacing: 6) {
                        Skeleton(width: 180, height: 12)
                        Skeleton(width: 110, height: 10)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .accessibilityLabel("Loading")
    }
}

struct ErrorStateView: View {
    let error: Error
    var retry: (() -> Void)?
    var body: some View {
        let offline = (error as? APIError)?.isOffline == true
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: offline ? "wifi.slash" : "exclamationmark.triangle")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.Gradients.brand)
            Text(offline ? "You're offline" : "Something went wrong").font(Theme.Typography.media(18))
            Text(error.localizedDescription)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try again", action: retry).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.Gradients.brand)
                .padding(.bottom, Theme.Spacing.s)
            Text(title).font(Theme.Typography.media(20)).multilineTextAlignment(.center)
            Text(message).font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle(fullWidth: false)).padding(.top, Theme.Spacing.s)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

/// Loads async content and renders loading/error/content states consistently.
struct AsyncContent<Value, Content: View>: View {
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    var skeleton: AnyView = AnyView(SkeletonRows())
    @State private var state: LoadState<Value> = .loading

    var body: some View {
        Group {
            switch state {
            case .loading: skeleton
            case .failed(let e): ErrorStateView(error: e) { Task { await run() } }
            case .loaded(let v): content(v)
            }
        }
        .task { await run() }
    }

    private func run() async {
        if case .loaded = state {} else { state = .loading }
        do { state = .loaded(try await load()) } catch is CancellationError {} catch { state = .failed(error) }
    }
}

enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(Error)
}

// MARK: - Glass

struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.l
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

extension View {
    func glass(cornerRadius: CGFloat = Theme.Radius.l) -> some View { modifier(GlassBackground(cornerRadius: cornerRadius)) }

    /// Standard screen background.
    func streameroScreen() -> some View {
        background(Theme.Palette.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
    }
}

/// Offline indicator shown at the top of screens when the network is unavailable.
struct OfflineBanner: View {
    var body: some View {
        Label("Offline — showing downloaded music", systemImage: "wifi.slash")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 6)
            .background(Theme.Palette.surfaceHighlight, in: Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Admin announcement from the remote config (Home and the welcome screen).
struct AnnouncementBanner: View {
    @State private var dismissedText: String?

    var body: some View {
        let a = AppearanceStore.shared.config.announcement
        if a.isVisible && dismissedText != a.text {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: symbol(a.style)).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint(a.style))
                Text(a.text).font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                Button { withAnimation(Theme.Motion.quick) { dismissedText = a.text } } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.Palette.textSecondary).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss announcement")
            }
            .padding(Theme.Spacing.m)
            .background(tint(a.style).opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(tint(a.style).opacity(0.45), lineWidth: 1))
            .padding(.horizontal, Theme.Spacing.screen)
            .accessibilityElement(children: .combine)
        }
    }

    private func symbol(_ style: AppConfig.AnnouncementStyle) -> String {
        switch style {
        case .info: "megaphone.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.seal.fill"
        }
    }

    private func tint(_ style: AppConfig.AnnouncementStyle) -> Color {
        switch style {
        case .info: Theme.Palette.blue
        case .warning: Theme.Palette.warning
        case .success: Theme.Palette.accent
        }
    }
}
