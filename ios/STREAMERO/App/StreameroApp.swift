import AVFoundation
import SwiftUI
import UIKit

@main
struct StreameroApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.player)
                .environment(model.library)
                .environment(model.settings)
                .environment(model.downloads)
                .environment(model.network)
                .preferredColorScheme(model.settings.values.appearance.colorScheme)
                .tint(Theme.Palette.accent)
                .onOpenURL { model.handle(url: $0) }
                .task { await model.bootstrap() }
        }
        .modelContainer(model.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIApplication.shared.beginReceivingRemoteControlEvents()
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
