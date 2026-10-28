import Foundation
import SyncCore
import UserNotifications

/// A local notification, in plain values so it can be compared in tests.
struct LocalNotification: Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    /// Seconds until it shows; `nil` shows it right away.
    var delay: TimeInterval?
}

/// What the notifier needs from the notification center. Tests use a stand-in.
protocol NotificationScheduling: Sendable {
    /// Adds `notification`, replacing a pending one with the same id.
    func schedule(_ notification: LocalNotification) async throws

    /// Removes the pending notification with this id, if there is one.
    func cancel(id: String) async

    /// Whether the owner lets the app show notifications.
    func isAllowed() async -> Bool
}

/// The real notification center.
struct SystemNotificationCenter: NotificationScheduling {
    func schedule(_ notification: LocalNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let trigger = notification.delay.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max($0, 1), repeats: false)
        }
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }

    func cancel(id: String) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    func isAllowed() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}

/// The outcome of the Advanced "test notification" button.
enum TestNotificationResult: Equatable {
    case scheduled, notAllowed, failed

    var message: String {
        switch self {
        case .scheduled: return "A test notification will show in 10 seconds. Lock your phone to see it."
        case .notAllowed: return "Notifications are off. Turn them on in the Settings app → TelegramPhotos."
        case .failed: return "Couldn't schedule the test notification. Share logs for details."
        }
    }
}

/// When to notify, and what to say (D18). Kept apart from the notification center so it can be tested.
enum NotificationRules {
    static let staleSyncId = "stale-sync"
    static let authLostId = "auth-lost"
    static let testId = "test-notification"
    /// How long without progress before "Backups paused" shows.
    static let staleAfter: TimeInterval = 48 * 3600
    /// The "log in again" notification shows at most once in this window.
    static let authLostInterval: TimeInterval = 24 * 3600

    static let staleSync = LocalNotification(
        id: staleSyncId, title: "Backups paused", body: "No photos synced in 2 days — open TelegramPhotos.",
        delay: staleAfter)

    static let authLost = LocalNotification(
        id: authLostId, title: "Telegram logged out", body: "Open TelegramPhotos to log in again.", delay: nil)

    static let test = LocalNotification(
        id: testId, title: "Test notification", body: "Notifications from TelegramPhotos work.", delay: 10)

    /// A run that uploaded something, or found nothing left to do, pushes the "Backups paused" reminder back.
    ///
    /// Runs stopped by a condition (no Wi-Fi, no charger, …) without uploading anything don't count.
    static func postponesStaleReminder(_ report: SyncReport) -> Bool {
        report.uploaded > 0 || (report.blockedBy == nil && report.remainingEligible == 0)
    }

    /// Whether a run that ended with `report` should show "Telegram logged out" now.
    static func shouldNotifyAuthLost(_ report: SyncReport, lastNotifiedAt: Date?, now: Date) -> Bool {
        guard report.blockedBy == .authLost else { return false }
        guard let lastNotifiedAt else { return true }
        return now.timeIntervalSince(lastNotifiedAt) >= authLostInterval
    }
}

/// Keeps the "Backups paused" reminder pushed back while syncs succeed, and says when Telegram logged out.
actor SyncNotifications: SyncObserver {
    static let shared = SyncNotifications()

    private let center: NotificationScheduling
    private let settings: AppSettings
    private let clock: Clock
    private let logger: FileLogger

    init(
        center: NotificationScheduling = SystemNotificationCenter(),
        settings: AppSettings = .shared,
        clock: Clock = SystemClock(),
        logger: FileLogger = .shared
    ) {
        self.center = center
        self.settings = settings
        self.clock = clock
        self.logger = logger
    }

    func handle(_ event: SyncEvent) async {
        guard case .runFinished(let report) = event else { return }
        if NotificationRules.postponesStaleReminder(report) {
            await center.cancel(id: NotificationRules.staleSyncId)
            await schedule(NotificationRules.staleSync)
        }
        let now = clock.now()
        if NotificationRules.shouldNotifyAuthLost(report, lastNotifiedAt: settings.authLostNotifiedAt, now: now),
            await schedule(NotificationRules.authLost)
        {
            settings.authLostNotifiedAt = now
        }
    }

    /// Shows a test notification in 10 seconds (Settings → Advanced).
    func scheduleTest() async -> TestNotificationResult {
        guard await center.isAllowed() else {
            logger.info("Test notification skipped: not allowed", category: "notifications")
            return .notAllowed
        }
        return await schedule(NotificationRules.test) ? .scheduled : .failed
    }

    @discardableResult
    private func schedule(_ notification: LocalNotification) async -> Bool {
        do {
            try await center.schedule(notification)
            logger.info("Notification scheduled: \(notification.id)", category: "notifications")
            return true
        } catch {
            let nsError = error as NSError
            logger.warning(
                "Notification \(notification.id) failed: \(nsError.domain) \(nsError.code)", category: "notifications")
            return false
        }
    }
}
