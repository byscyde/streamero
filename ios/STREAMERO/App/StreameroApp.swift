import AVFoundation
import SwiftUI
import UIKit

@main
struct StreameroApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.player)
                .environment(model.library)
                .environment(model.settings)
                .environment(model.downloads)
                .environment(model.network)
                .environment(model.sync)
                .environment(model.appearance)
                .preferredColorScheme(model.settings.values.appearance.colorScheme)
                .tint(Theme.Palette.accent)
                .onOpenURL { model.handle(url: $0) }
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    guard model.phase == .signedIn, phase != .inactive else { return }
                    model.sync.scenePhaseChanged(active: phase == .active)
                }
        }
        .modelContainer(model.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        SyncCenter.registerBackgroundTask() // must happen before launch finishes
        return true
    }

    /// The phone UI is a SwiftUI WindowGroup; CarPlay gets its own UIKit template scene.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        return config
    }

    /// Background download sessions relaunch the app to deliver completed transfers.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { AppModel.shared?.downloads.backgroundCompletion = completionHandler }
    }
}
