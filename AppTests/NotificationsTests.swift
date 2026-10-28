import SyncCore
import XCTest

@testable import TelegramPhotos

private actor RecordingCenter: NotificationScheduling {
    enum Call: Equatable {
        case schedule(LocalNotification)
        case cancel(String)
    }

    private(set) var calls: [Call] = []
    private let allowed: Bool
    private let failing: Bool

    init(allowed: Bool = true, failing: Bool = false) {
        self.allowed = allowed
        self.failing = failing
    }

    func schedule(_ notification: LocalNotification) async throws {
        if failing { throw NSError(domain: "UNErrorDomain", code: 1) }
        calls.append(.schedule(notification))
    }

    func cancel(id: String) async {
        calls.append(.cancel(id))
    }

    func isAllowed() async -> Bool { allowed }
}

private final class MovableClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current += seconds
        lock.unlock()
    }
}

final class NotificationsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(uploaded: Int = 0, remaining: Int = 0, blockedBy: BlockReason? = nil) -> SyncReport {
        SyncReport(
            trigger: .backgroundProcessing, startedAt: start, endedAt: start, uploaded: uploaded, failed: 0,
            skipped: 0, remainingEligible: remaining, blockedBy: blockedBy)
    }

    private func makeSettings() throws -> AppSettings {
        let suite = "NotificationsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }

    func testStaleReminderIsPostponedOnlyByProgressOrNothingLeft() {
        XCTAssertTrue(NotificationRules.postponesStaleReminder(report(uploaded: 1, remaining: 5)))
        XCTAssertTrue(NotificationRules.postponesStaleReminder(report(uploaded: 2, blockedBy: .needsCharger)))
        XCTAssertTrue(NotificationRules.postponesStaleReminder(report()))
        XCTAssertFalse(NotificationRules.postponesStaleReminder(report(remaining: 3)))
        XCTAssertFalse(NotificationRules.postponesStaleReminder(report(blockedBy: .expensiveNetwork)))
        XCTAssertFalse(NotificationRules.postponesStaleReminder(report(blockedBy: .needsCharger)))
        XCTAssertFalse(NotificationRules.postponesStaleReminder(report(blockedBy: .authLost)))
    }

    func testAuthLostAtMostOncePerDay() {
        let lost = report(blockedBy: .authLost)
        XCTAssertTrue(NotificationRules.shouldNotifyAuthLost(lost, lastNotifiedAt: nil, now: start))
        XCTAssertFalse(
            NotificationRules.shouldNotifyAuthLost(lost, lastNotifiedAt: start, now: start + 23 * 3600))
        XCTAssertTrue(NotificationRules.shouldNotifyAuthLost(lost, lastNotifiedAt: start, now: start + 24 * 3600))
        XCTAssertFalse(NotificationRules.shouldNotifyAuthLost(report(), lastNotifiedAt: nil, now: start))
    }

    func testStaleReminderContent() {
        let notification = NotificationRules.staleSync
        XCTAssertEqual(notification.id, "stale-sync")
        XCTAssertEqual(notification.delay, 48 * 3600)
        XCTAssertEqual(notification.title, "Backups paused")
        XCTAssertEqual(notification.body, "No photos synced in 2 days — open TelegramPhotos.")
        XCTAssertNil(NotificationRules.authLost.delay)
        XCTAssertEqual(NotificationRules.test.delay, 10)
    }

    func testSuccessfulRunReplacesTheStaleReminder() async throws {
        let center = RecordingCenter()
        let notifier = SyncNotifications(center: center, settings: try makeSettings(), clock: MovableClock(start))
        await notifier.handle(.runFinished(report(uploaded: 3)))
        let calls = await center.calls
        XCTAssertEqual(calls, [.cancel("stale-sync"), .schedule(NotificationRules.staleSync)])
    }

    func testBlockedRunAndOtherEventsLeaveTheReminderAlone() async throws {
        let center = RecordingCenter()
        let notifier = SyncNotifications(center: center, settings: try makeSettings(), clock: MovableClock(start))
        await notifier.handle(.runStarted(total: 3, totalBytes: 0))
        await notifier.handle(.runFinished(report(remaining: 3, blockedBy: .expensiveNetwork)))
        let calls = await center.calls
        XCTAssertEqual(calls, [])
    }

    func testAuthLostNotifiesOncePerDay() async throws {
        let center = RecordingCenter()
        let clock = MovableClock(start)
        let settings = try makeSettings()
        let notifier = SyncNotifications(center: center, settings: settings, clock: clock)
        let lost = SyncEvent.runFinished(report(remaining: 4, blockedBy: .authLost))

        await notifier.handle(lost)
        clock.advance(by: 3600)
        await notifier.handle(lost)
        var calls = await center.calls
        XCTAssertEqual(calls, [.schedule(NotificationRules.authLost)])
        XCTAssertEqual(settings.authLostNotifiedAt, start)

        clock.advance(by: 23 * 3600)
        await notifier.handle(lost)
        calls = await center.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testFailedAuthLostNotificationIsRetriedNextRun() async throws {
        let settings = try makeSettings()
        let notifier = SyncNotifications(
            center: RecordingCenter(failing: true), settings: settings, clock: MovableClock(start))
        await notifier.handle(.runFinished(report(blockedBy: .authLost)))
        XCTAssertNil(settings.authLostNotifiedAt)
    }

    func testTestNotification() async throws {
        let allowed = SyncNotifications(center: RecordingCenter(), settings: try makeSettings())
        let scheduled = await allowed.scheduleTest()
        XCTAssertEqual(scheduled, .scheduled)

        let denied = SyncNotifications(center: RecordingCenter(allowed: false), settings: try makeSettings())
        let notAllowed = await denied.scheduleTest()
        XCTAssertEqual(notAllowed, .notAllowed)

        let failing = SyncNotifications(center: RecordingCenter(failing: true), settings: try makeSettings())
        let failed = await failing.scheduleTest()
        XCTAssertEqual(failed, .failed)
    }
}
