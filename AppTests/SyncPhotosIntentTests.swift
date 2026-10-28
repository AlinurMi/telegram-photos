import SyncCore
import XCTest

@testable import TelegramPhotos

final class SyncPhotosIntentTests: XCTestCase {
    private func report(
        uploaded: Int = 0, failed: Int = 0, remaining: Int = 0, blockedBy: BlockReason? = nil
    ) -> SyncReport {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return SyncReport(
            trigger: .intent, startedAt: date, endedAt: date, uploaded: uploaded, failed: failed, skipped: 0,
            remainingEligible: remaining, blockedBy: blockedBy)
    }

    func testAlreadySyncing() {
        XCTAssertEqual(SyncIntentDialog.text(for: nil), "Already syncing.")
    }

    func testUpToDate() {
        XCTAssertEqual(SyncIntentDialog.text(for: report()), "Up to date.")
    }

    func testUploadedAndWaiting() {
        XCTAssertEqual(SyncIntentDialog.text(for: report(uploaded: 5, remaining: 12)), "Uploaded 5, 12 waiting.")
        XCTAssertEqual(
            SyncIntentDialog.text(for: report(uploaded: 5, remaining: 12, blockedBy: .deadline)),
            "Uploaded 5, 12 waiting.")
        XCTAssertEqual(SyncIntentDialog.text(for: report(uploaded: 3)), "Uploaded 3.")
        XCTAssertEqual(SyncIntentDialog.text(for: report(uploaded: 2, failed: 1)), "Uploaded 2, 1 failed.")
    }

    func testBlocked() {
        XCTAssertEqual(SyncIntentDialog.text(for: report(blockedBy: .expensiveNetwork)), "Waiting for Wi-Fi.")
        XCTAssertEqual(
            SyncIntentDialog.text(for: report(uploaded: 4, blockedBy: .needsCharger)),
            "Uploaded 4. Older items will upload while charging.")
        XCTAssertEqual(
            SyncIntentDialog.text(for: report(blockedBy: .authLost)), "Open TelegramPhotos and log in again.")
        XCTAssertEqual(SyncIntentDialog.text(for: report(blockedBy: .cancelled)), "Stopped.")
    }

    func testIntentBudget() throws {
        let suite = "SyncPhotosIntentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.intentBudgetSeconds, 25)
        defaults.set(40.0, forKey: AppSettings.intentBudgetSecondsKey)
        XCTAssertEqual(settings.intentBudgetSeconds, 40)
        defaults.set(0.0, forKey: AppSettings.intentBudgetSecondsKey)
        XCTAssertEqual(settings.intentBudgetSeconds, 25)
    }
}
