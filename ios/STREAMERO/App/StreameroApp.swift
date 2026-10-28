import StreameroKit
import SwiftUI

@main
struct StreameroApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { app.lockIfNeeded() }
                    if phase == .active, app.isLocked { app.unlock() }
                }
        }
    }
}

enum AppTab: Hashable { case dashboard, requests, library, activity, more }

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var tab: AppTab = .dashboard

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $tab) {
                NavigationStack { DashboardView(tab: $tab) }
                    .tabItem { Label("Dashboard", systemImage: "square.grid.2x2.fill") }
                    .tag(AppTab.dashboard)
                NavigationStack { RequestsView() }
                    .tabItem { Label("Requests", systemImage: "tray.and.arrow.down.fill") }
                    .tag(AppTab.requests)
                NavigationStack { LibraryView() }
                    .tabItem { Label("Library", systemImage: "film.stack.fill") }
                    .tag(AppTab.library)
                NavigationStack { ActivityView() }
                    .tabItem { Label("Activity", systemImage: "arrow.down.circle.fill") }
                    .tag(AppTab.activity)
                NavigationStack { MoreView() }
                    .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                    .tag(AppTab.more)
            }
            ToastView().animation(.spring, value: app.toast)
        }
        .overlay {
            if app.isLocked { LockView() }
        }
        .sheet(isPresented: .constant(!app.hasAnyConfigured && !app.isLocked)) {
            NavigationStack { WelcomeView() }
                .interactiveDismissDisabled()
        }
    }
}

struct LockView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                BrandMark(size: 72)
                Text("Streamero is locked").font(Theme.titleFont)
                Button { app.unlock() } label: { Label("Unlock", systemImage: "faceid") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("unlockButton")
            }
        }
        .onAppear { app.unlock() }
    }
}

/// The Streamero mark: red play triangle with two stream waves on a dark rounded square.
struct BrandMark: View {
    var size: CGFloat = 56
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.227, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.165, green: 0.165, blue: 0.18), Color(red: 0.043, green: 0.043, blue: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Canvas { context, canvas in
                let s = canvas.width / 1024
                var triangle = Path()
                triangle.move(to: CGPoint(x: 254 * s, y: 322 * s))
                triangle.addLine(to: CGPoint(x: 254 * s, y: 702 * s))
                triangle.addLine(to: CGPoint(x: 514 * s, y: 512 * s))
                triangle.closeSubpath()
                let red = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Color(red: 1, green: 0.353, blue: 0.392), Color(red: 0.827, green: 0.071, blue: 0.122)]),
                    startPoint: CGPoint(x: 254 * s, y: 322 * s), endPoint: CGPoint(x: 514 * s, y: 702 * s))
                context.fill(triangle, with: red)
                context.stroke(triangle, with: red, style: StrokeStyle(lineWidth: 72 * s, lineCap: .round, lineJoin: .round))
                var inner = Path()
                inner.addArc(center: CGPoint(x: 504 * s, y: 512 * s), radius: 156 * s, startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: false)
                context.stroke(inner, with: .color(.white), style: StrokeStyle(lineWidth: 64 * s, lineCap: .round))
                var outer = Path()
                outer.addArc(center: CGPoint(x: 520 * s, y: 512 * s), radius: 274 * s, startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: false)
                context.stroke(outer, with: .color(Color(red: 1, green: 0.27, blue: 0.32)), style: StrokeStyle(lineWidth: 64 * s, lineCap: .round))
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Streamero")
    }
}
