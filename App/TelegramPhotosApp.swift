import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundSync.shared.register()
        Task { await LiveActivityController.shared.endLeftovers() }
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
            RootView()
                .environment(AppModel.shared)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background {
                BackgroundSync.scheduleBackfill()
            }
            guard phase == .active, !didStartLaunchSync else { return }
            didStartLaunchSync = true
            Task { await SyncCoordinator.shared.syncOnLaunch() }
        }
    }
}

/// Shows the setup flow until setup is finished, then the main screen.
struct RootView: View {
    @AppStorage(AppSettings.setupCompletedKey) private var setupCompleted = false

    var body: some View {
        if setupCompleted {
            StatusView()
        } else {
            SetupFlowView(telegram: .shared)
        }
    }
}
