import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SpikeTasks.registerSyncNow()
        return true
    }
}

@main
struct TelegramPhotosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var didStartLaunchSync = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppModel.shared)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, !didStartLaunchSync else { return }
            didStartLaunchSync = true
            Task { await SyncCoordinator.shared.syncOnLaunch() }
        }
    }
}
