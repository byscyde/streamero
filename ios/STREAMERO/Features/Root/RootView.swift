import StreameroCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            switch model.phase {
            case .launching:
                LaunchView()
            case .onboarding:
                OnboardingView().transition(.opacity)
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
        VStack(spacing: Theme.Spacing.l) {
            BrandMark(size: 72)
            ProgressView().tint(Theme.Palette.textSecondary)
        }
    }
}

/// Wordmark + glyph used on launch, onboarding and auth.
struct BrandMark: View {
    var size: CGFloat = 56
    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ZStack {
                Circle().fill(Theme.Palette.surfaceRaised).frame(width: size * 1.6, height: size * 1.6)
                Image(systemName: "dot.radiowaves.right")
                    .font(.system(size: size * 0.8, weight: .bold))
                    .foregroundStyle(Theme.Gradients.brand)
            }
            Text("STREAMERO")
                .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                .tracking(size * 0.06)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("STREAMERO")
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    tabContent(tab)
                        .streameroDestinations()
                        .safeAreaInset(edge: .bottom) {
                            if player.hasContent { Color.clear.frame(height: Theme.Size.miniPlayerHeight + Theme.Spacing.s) }
                        }
                }
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
        .overlay(alignment: .bottom) {
            if player.hasContent {
                MiniPlayerView()
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.bottom, 52) // sits above the tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if !network.isOnline { OfflineBanner().padding(.top, 4).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .animation(Theme.Motion.standard, value: player.hasContent)
        .animation(Theme.Motion.standard, value: network.isOnline)
        .fullScreenCover(isPresented: $model.isPlayerExpanded) {
            NowPlayingView()
        }
        .sheet(item: $model.addToPlaylist) { request in
            AddToPlaylistSheet(tracks: request.tracks)
        }
    }

    @ViewBuilder private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .search: SearchView()
        case .library: LibraryView()
        case .videos: VideosView()
        case .profile: ProfileView()
        }
    }
}

struct ToastOverlay: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let toast = model.toast {
            Label(toast.message, systemImage: toast.symbol)
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .glass(cornerRadius: 22)
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
