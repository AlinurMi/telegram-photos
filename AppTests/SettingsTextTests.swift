import SyncCore
import XCTest

@testable import TelegramPhotos

final class SettingsTextTests: XCTestCase {
    func testRebuildResult() {
        XCTAssertEqual(SettingsText.rebuilt(ChannelCheckResult()), "Already matches the channel")
        XCTAssertEqual(
            SettingsText.rebuilt(ChannelCheckResult(markedDone: 1)), "Marked 1 item as already uploaded")
        XCTAssertEqual(
            SettingsText.rebuilt(ChannelCheckResult(markedDone: 5)), "Marked 5 items as already uploaded")
        XCTAssertEqual(SettingsText.rebuilt(ChannelCheckResult(removed: 2)), "2 items no longer in the channel")
        XCTAssertEqual(
            SettingsText.rebuilt(ChannelCheckResult(markedDone: 3, removed: 1)),
            "Marked 3 items as already uploaded. 1 item no longer in the channel")
    }

    func testRetryResult() {
        XCTAssertEqual(SettingsText.retried(1), "1 item will be tried again")
        XCTAssertEqual(SettingsText.retried(3), "3 items will be tried again")
    }

    func testFailureMessages() {
        XCTAssertEqual(SettingsText.failure(CoordinatorError.busy), "A sync is running. Try again when it's done.")
        XCTAssertEqual(
            SettingsText.failure(UploadError(kind: .authLost, message: "notLoggedIn")), "Log in to Telegram first.")
        XCTAssertEqual(
            SettingsText.failure(UploadError(kind: .transient, message: "telegramNotReady")),
            "Couldn't reach Telegram. Try again.")
        XCTAssertEqual(SettingsText.failure(TelegramError(message: "Too many requests.")), "Too many requests.")
        XCTAssertEqual(
            SettingsText.failure(CocoaError(.fileNoSuchFile)), "Something went wrong. Share logs for details.")
    }

    func testOnlyRetryRunsWithoutConfirmation() {
        XCTAssertFalse(MaintenanceAction.retryFailed.needsConfirmation)
        XCTAssertTrue(MaintenanceAction.rebuild.needsConfirmation)
        XCTAssertTrue(MaintenanceAction.logOut.needsConfirmation)
        XCTAssertTrue(MaintenanceAction.reset.needsConfirmation)
        XCTAssertTrue(MaintenanceAction.reset.isDestructive)
        XCTAssertFalse(MaintenanceAction.rebuild.isDestructive)
    }
}
