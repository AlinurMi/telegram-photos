import SyncCore
import XCTest

@testable import TelegramPhotos

final class StatusSummaryTests: XCTestCase {
    private func summary(_ phase: AppModel.Phase, _ counts: StatusCounts = StatusCounts()) -> StatusSummary {
        StatusSummary.make(phase: phase, counts: counts)
    }

    func testIdle() {
        XCTAssertEqual(summary(.idle), StatusSummary(title: "Up to date"))
        XCTAssertEqual(summary(.idle, StatusCounts(pending: 1)).title, "1 item to upload")
        XCTAssertEqual(summary(.idle, StatusCounts(pending: 3, uploading: 1)).title, "4 items to upload")
    }

    func testSyncing() {
        XCTAssertEqual(
            summary(.syncing(done: 0, total: 0, fileName: nil, bytesRemaining: 0)),
            StatusSummary(title: "Checking for new photos…"))
        XCTAssertEqual(
            summary(.syncing(done: 36, total: 120, fileName: "IMG_0037.HEIC", bytesRemaining: 0)),
            StatusSummary(title: "Syncing 37 of 120", detail: "IMG_0037.HEIC", progress: 0.3))
        XCTAssertEqual(summary(.syncing(done: 0, total: 5, fileName: nil, bytesRemaining: 0)).title, "Syncing 1 of 5")
        XCTAssertEqual(summary(.syncing(done: 5, total: 5, fileName: nil, bytesRemaining: 0)).progress, 1)
    }

    func testBlocked() {
        XCTAssertEqual(summary(.blocked(.noNetwork)), StatusSummary(title: "Waiting for internet"))
        XCTAssertEqual(
            summary(.blocked(.expensiveNetwork)), StatusSummary(title: "Waiting for Wi-Fi", action: .useCellular))
        XCTAssertEqual(
            summary(.blocked(.needsCharger), StatusCounts(pending: 900, backfillPending: 812)).title,
            "812 older items will upload while charging")
        XCTAssertEqual(
            summary(.blocked(.needsCharger), StatusCounts(pending: 1, backfillPending: 1)).title,
            "1 older item will upload while charging")
        XCTAssertEqual(summary(.blocked(.authLost)).title, "Log in again")
        XCTAssertEqual(summary(.blocked(.authLost)).action, .logIn)
        XCTAssertEqual(
            summary(.blocked(.noLibraryAccess)),
            StatusSummary(title: "Full Photos access needed", action: .openSettings))
        XCTAssertEqual(summary(.blocked(.lowDisk)), StatusSummary(title: "Free up space on your iPhone"))
        XCTAssertEqual(summary(.blocked(.cancelled)), StatusSummary(title: "Up to date"))
    }

    func testCountersQueueIncludesInterruptedUploads() {
        XCTAssertEqual(StatusSummary.queued(StatusCounts(pending: 2, uploading: 1, failed: 4)), 3)
    }

    func testLastSynced() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(StatusSummary.lastSynced(nil, now: now), "Never synced")
        XCTAssertEqual(StatusSummary.lastSynced(now.addingTimeInterval(-20), now: now), "Last synced just now")
        let older = StatusSummary.lastSynced(now.addingTimeInterval(-7_200), now: now)
        XCTAssertTrue(older.hasPrefix("Last synced "))
        XCTAssertNotEqual(older, "Last synced just now")
    }
}
