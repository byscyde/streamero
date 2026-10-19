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
                Theme.Palette.surfaceHighlight
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(Theme.Gradients.brand)
                    .opacity(0.8)
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
    var cornerRadius: CGFloat = Theme.Radius.l
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
    var body: some View {
        if urls.count >= 4 {
            let half = size / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) { ArtworkView(url: urls[0], size: half, cornerRadius: 0); ArtworkView(url: urls[1], size: half, cornerRadius: 0) }
                HStack(spacing: 0) { ArtworkView(url: urls[2], size: half, cornerRadius: 0); ArtworkView(url: urls[3], size: half, cornerRadius: 0) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
        } else {
            ArtworkView(url: urls.first, size: size, placeholderSymbol: "music.note.list")
        }
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.vertical, 14)
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 48)
            .background(Theme.Palette.accent.opacity(enabled ? 1 : 0.4), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

/// Outlined pill (e.g. "Follow", "Continue with Apple").
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 32)
            .overlay(Capsule().strokeBorder(Theme.Palette.textTertiary, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

/// The big green play button on collection headers.
struct PlayCircleButton: View {
    var isPlaying = false
    var size: CGFloat = 56
    let action: () -> Void
    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .black))
                .foregroundStyle(Theme.Palette.onAccent)
                .offset(x: isPlaying ? 0 : size * 0.03)
                .frame(width: size, height: size)
                .background(Theme.Palette.accent, in: Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
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
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(minWidth: Theme.Size.minTapTarget, minHeight: Theme.Size.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Text & badges

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var action: (title: String, run: () -> Void)?
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle { Text(subtitle).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary) }
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.Palette.textPrimary)
            }
            Spacer()
            if let action {
                Button(action.title, action: action.run).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
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
            .foregroundStyle(lossless ? Theme.Palette.turquoise : Theme.Palette.textSecondary)
            .overlay(Capsule().strokeBorder(lossless ? Theme.Palette.turquoise : Theme.Palette.separator, lineWidth: 1))
    }
}

/// Filter pill (All / Music / Videos, Playlists / Artists / Albums…).
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
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .foregroundStyle(selected ? Theme.Palette.onAccent : Theme.Palette.textPrimary)
                .background(selected ? Theme.Palette.accent : Theme.Palette.surfaceHighlight, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Circular avatar button that opens the profile menu (top-left of the main screens).
struct AvatarButton: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat = 32
    var body: some View {
        Button { withAnimation(Theme.Motion.standard) { app.isMenuOpen = true } } label: {
            ZStack {
                Circle().fill(Theme.Palette.accent)
                Text(String(app.user?.displayName.first ?? "S").uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Theme.Palette.onAccent)
                if let url = app.avatarURL { ArtworkView(url: url, size: size, circular: true) }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile and settings")
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
            Text(offline ? "You're offline" : "Something went wrong").font(Theme.Typography.headline)
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
            Text(title).font(Theme.Typography.title).multilineTextAlignment(.center)
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
