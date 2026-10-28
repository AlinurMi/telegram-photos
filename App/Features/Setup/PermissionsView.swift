import SwiftUI
import SyncCore
import UserNotifications

/// Asks for Full Access to Photos, or explains how to turn it on in Settings.
struct PhotosPermissionView: View {
    let access: LibraryAuthorization
    /// Called after the system prompt closes, so the flow can check the new access level.
    let onChange: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var isAsking = false

    var body: some View {
        if access == .notDetermined {
            ScreenLayout(title: "Allow Photos", subtitle: "Choose Full Access so every photo and video is backed up.") {
                PrimaryButton(title: "Continue", isWorking: isAsking, action: ask)
            }
        } else {
            ScreenLayout(title: "TelegramPhotos needs Full Access", subtitle: "Tap Photos, then Full Access.") {
                PrimaryButton(title: "Open Settings", action: openSettings)
            }
        }
    }

    private func ask() {
        guard !isAsking else { return }
        isAsking = true
        Task {
            let result = await PhotoKitLibrary().requestAuthorization()
            log.info("Photos access: \(result)", category: "setup")
            isAsking = false
            onChange()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

/// Asks to send notifications. Saying no is fine; setup continues either way.
struct NotificationsPermissionView: View {
    /// Called once the owner has answered or skipped.
    let onDone: () -> Void

    @State private var isAsking = false

    var body: some View {
        ScreenLayout(title: "Notifications", subtitle: "Only used to tell you if backups stop.") {
            VStack(spacing: 8) {
                PrimaryButton(title: "Allow notifications", isWorking: isAsking, action: ask)
                QuietButton(title: "Not now", action: onDone)
                    .disabled(isAsking)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Whether the owner hasn't been asked about notifications yet.
    static func isUndecided() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    private func ask() {
        guard !isAsking else { return }
        isAsking = true
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [
                    .alert, .sound,
                ])
                log.info("Notifications allowed: \(granted)", category: "setup")
            } catch {
                log.warning("Notification permission request failed: \(error)", category: "setup")
            }
            isAsking = false
            onDone()
        }
    }
}
