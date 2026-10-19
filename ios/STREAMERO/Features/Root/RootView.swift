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

/// STREAMERO's own mark (not derived from any other service's logo).
struct BrandMark: View {
    var size: CGFloat = 56
    var showsName = true
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "dot.radiowaves.right")
                .font(.system(size: size * 0.9, weight: .bold))
                .foregroundStyle(Theme.Palette.textPrimary)
            if showsName {
                Text("STREAMERO")
                    .font(.system(size: size * 0.36, weight: .black))
                    .tracking(size * 0.04)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("STREAMERO")
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @Environment(NetworkMonitor.self) private var network

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.92)
        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(white: 0.7, alpha: 1)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(white: 0.7, alpha: 1), .font: UIFont.systemFont(ofSize: 10, weight: .medium)]
        item.selected.iconColor = .white
        item.selected.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 10, weight: .semibold)]
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: Binding(get: { model.selectedTab }, set: { tab in
            if tab == .create {
                model.showCreatePlaylist = true // "Create" opens a sheet instead of switching tabs
            } else {
                if tab == model.selectedTab { model.popToRoot(tab) }
                model.selectedTab = tab
            }
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
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.bottom, 54) // sits on top of the tab bar
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
        case .library, .create: LibraryView()
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
                            Text(app.user?.displayName ?? "Listener").font(.system(size: 18, weight: .bold))
                            Text("View profile").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xl)
                    .contentShape(Rectangle())
                    .onTapGesture { go(.profile) }
                    Divider().overlay(Theme.Palette.separator)
                    item("Listening history", "clock.arrow.circlepath") { go(.recentlyPlayed) }
                    item("Downloads", "arrow.down.circle") { go(.downloads) }
                    item("Liked videos", "play.rectangle") { go(.likedVideos) }
                    item("YouTube", "play.tv") { go(.youtube) }
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
