import AppIntents

/// Makes "Sync Photos" available in Shortcuts and Siri without any setup.
struct TelegramPhotosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncPhotosIntent(),
            phrases: ["Sync photos with \(.applicationName)"],
            shortTitle: "Sync Photos",
            systemImageName: "arrow.up.circle")
    }
}
