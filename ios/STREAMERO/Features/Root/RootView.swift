import StreameroCore
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            switch model.phase {
            case .launching:
                LaunchView()
            case .signedOut:
                AuthFlowView().transition(.opacity)
            case .signedIn:
                MainTabView().transition(.opacity)
            }
        }
        .animation(Theme.Motion.standard, value: model.phase)
        .overlay(alignment: .top) { ToastOverlay() }
        .sheet(item: Binding(get: { model.pendingDeepLink.map(DeepLinkSheet.init) }, set: { if $0 == nil { model.pendingDeepLink = nil } })) { link in
            DeepLinkView(link: link.link)
        }
    }
}

struct DeepLinkSheet: Identifiable {
    let link: DeepLink
    var id: String { String(describing: link) }
}

struct LaunchView: View {
    var body: some View {
        BrandMark(size: 64)
    }
}

/// STREAMERO's own mark (design/logo-mark.svg, viewBox 1024): a red play triangle sending out two
/// stream waves on a dark rounded square. Drawn in SwiftUI so it stays sharp at every size.
struct BrandMark: View {
    var size: CGFloat = 56
    var showsName = true
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 232 / 1024, style: .continuous)
                    .fill(RadialGradient(colors: [Color(hex: 0x2A2A2E), Color(hex: 0x0B0B0D)], center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: size))
                BrandGlyph(size: size)
            }
            .frame(width: size, height: size)
            if showsName {
                Text(AppearanceStore.shared.brand.appName)
                    .font(.system(size: size * 0.32, weight: .black, design: .monospaced))
                    .tracking(size * 0.03)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppearanceStore.shared.brand.appName)
    }
}

/// The mark's triangle and waves without the tile (sits on artwork, e.g. playlist covers).
struct BrandGlyph: View {
    var size: CGFloat
    var body: some View {
        let k = size / 1024
        let red = LinearGradient(colors: [Color(hex: 0xFF5A64), Color(hex: 0xD3121F)], startPoint: UnitPoint(x: 0.21, y: 0.28), endPoint: UnitPoint(x: 0.54, y: 0.72))
        ZStack {
            LogoTriangle().fill(red)
            LogoTriangle().stroke(red, style: StrokeStyle(lineWidth: 72 * k, lineCap: .round, lineJoin: .round))
            LogoArc(centerX: 512, radius: 150, halfAngleDegrees: 47.15)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 64 * k, lineCap: .round))
            LogoArc(centerX: 529.9, radius: 262, halfAngleDegrees: 47.77)
                .stroke(Color(hex: 0xFF4552), style: StrokeStyle(lineWidth: 64 * k, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Play triangle of the logo (SVG points shifted by the group's translate(-46 0)).
struct LogoTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 1024
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 254 * k, y: rect.minY + 322 * k))
        p.addLine(to: CGPoint(x: rect.minX + 254 * k, y: rect.minY + 702 * k))
        p.addLine(to: CGPoint(x: rect.minX + 514 * k, y: rect.minY + 512 * k))
        p.closeSubpath()
        return p
    }
}

/// One stream wave: a circular arc to the right of the triangle, symmetric around y = 512.
struct LogoArc: Shape {
    let centerX: CGFloat
    let radius: CGFloat
    let halfAngleDegrees: Double

    func path(in rect: CGRect) -> Path {
        let k = rect.width / 1024
        let cx = rect.minX + centerX * k
        let cy = rect.minY + 512 * k
        let r = radius * k
        let half = halfAngleDegrees * Double.pi / 180
        var p = Path()
        let steps = 40
        for i in 0...steps {
            let a = -half + 2 * half * Double(i) / Double(steps)
            let point = CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a)))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        return p
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @Environment(NetworkMonitor.self) private var network

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Theme.Palette.backgroundUIColor.withAlphaComponent(0.97)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.06)
        let item = UITabBarItemAppearance()
        let dim = UIColor(white: 0.72, alpha: 1)
        item.normal.iconColor = dim
        item.normal.titleTextAttributes = [.foregroundColor: dim, .font: UIFont.systemFont(ofSize: 11, weight: .regular)]
        item.selected.iconColor = .white
        item.selected.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 11, weight: .semibold)]
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: Binding(get: { model.selectedTab }, set: { tab in
            if tab == model.selectedTab { model.popToRoot(tab) }
            model.selectedTab = tab
        })) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack(path: model.pathBinding(tab)) {
                    tabContent(tab)
                        .streameroDestinations()
                        .safeAreaInset(edge: .bottom) {
                            if player.hasContent { Color.clear.frame(height: Theme.Size.miniPlayerHeight + Theme.Spacing.s) }
                        }
                }
                .tabItem { Label(tab.title, systemImage: model.selectedTab == tab ? tab.selectedSymbol : tab.symbol) }
                .tag(tab)
            }
        }
        .tint(.white)
        .overlay(alignment: .bottom) {
            if player.hasContent {
                MiniPlayerView()
                    .padding(.bottom, 49) // sits directly on top of the tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if !network.isOnline { OfflineBanner().padding(.top, 4).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay { ProfileMenu() }
        .animation(Theme.Motion.standard, value: player.hasContent)
        .animation(Theme.Motion.standard, value: network.isOnline)
        .fullScreenCover(isPresented: $model.isPlayerExpanded) { NowPlayingView() }
        .sheet(item: $model.addToPlaylist) { request in AddToPlaylistSheet(tracks: request.tracks) }
        .sheet(isPresented: $model.showCreatePlaylist) { CreatePlaylistSheet() }
    }

    @ViewBuilder private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .search: SearchView()
        case .explore: ExploreView()
        case .library: LibraryView()
        }
    }
}

/// Slide-in menu from the left (avatar tap): profile, history, downloads, settings, sign out.
struct ProfileMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack(alignment: .leading) {
            if app.isMenuOpen {
                Color.black.opacity(0.6).ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.Spacing.m) {
                        AvatarButton(size: 44).allowsHitTesting(false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.user?.displayName ?? "Listener").font(Theme.Typography.media(18))
                            Text("View profile").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xl)
                    .contentShape(Rectangle())
                    .onTapGesture { go(.profile) }
                    Divider().overlay(Theme.Palette.separator)
                    let features = AppearanceStore.shared.features
                    item("Listening history", "clock.arrow.circlepath") { go(.recentlyPlayed) }
                    if features.downloads { item("Downloads", "arrow.down.circle") { go(.downloads) } }
                    if features.videos { item("Liked videos", "play.rectangle") { go(.likedVideos) } }
                    if features.youtube { item("YouTube", "play.tv") { go(.youtube) } }
                    if features.equalizer { item("Equalizer", "slider.vertical.3") { go(.equalizer) } }
                    item("Settings and privacy", "gearshape") { go(.settings) }
                    Spacer()
                    item("Log out", "rectangle.portrait.and.arrow.right") {
                        close()
                        Task { await app.signOut() }
                    }
                    .padding(.bottom, Theme.Spacing.xl)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .frame(width: 300)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.Palette.surface.ignoresSafeArea())
                .transition(.move(edge: .leading))
                .gesture(DragGesture().onEnded { if $0.translation.width < -60 { close() } })
            }
        }
        .animation(Theme.Motion.standard, value: app.isMenuOpen)
    }

    private func item(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.l) {
                Image(systemName: symbol).font(.system(size: 20)).frame(width: 28)
                Text(title).font(.system(size: 16, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func close() { app.isMenuOpen = false }

    private func go(_ route: Route) {
        close()
        app.navigate(to: route)
    }
}

struct ToastOverlay: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let toast = model.toast {
            Label(toast.message, systemImage: toast.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, Theme.Spacing.s)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(2.4))
                    withAnimation(Theme.Motion.standard) { model.toast = nil }
                }
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
