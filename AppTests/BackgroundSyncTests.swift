import SyncCore
import XCTest

@testable import TelegramPhotos

final class BackgroundSyncTests: XCTestCase {
    private let steps = ContinuedSyncDisplay.stepsPerItem

    private func report(uploaded: Int = 0, failed: Int = 0, blockedBy: BlockReason? = nil) -> SyncReport {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return SyncReport(
            trigger: .manual, startedAt: date, endedAt: date, uploaded: uploaded, failed: failed, skipped: 0,
            remainingEligible: 0, blockedBy: blockedBy)
    }

    private func display(_ events: [SyncEvent]) -> ContinuedSyncDisplay {
        var display = ContinuedSyncDisplay()
        for event in events { display.apply(event) }
        return display
    }

    func testBeforeTheRunStarts() {
        let display = ContinuedSyncDisplay()
        XCTAssertEqual(display.subtitle, "Checking for new photos…")
        XCTAssertEqual(display.totalUnitCount, steps)
        XCTAssertEqual(display.completedUnitCount, 0)
    }

    func testNothingToUpload() {
        let started = display([.runStarted(total: 0, totalBytes: 0)])
        XCTAssertEqual(started.subtitle, "Nothing new to upload")
        let finished = display([.runStarted(total: 0, totalBytes: 0), .runFinished(report())])
        XCTAssertEqual(finished.subtitle, "Up to date")
        XCTAssertEqual(finished.completedUnitCount, finished.totalUnitCount)
    }

    func testUploadingShowsCountAndFileName() {
        let display = display([
            .runStarted(total: 120, totalBytes: 0),
            .unitStarted(index: 36, total: 120, fileName: "IMG_1234.HEIC", bytes: 2_000),
        ])
        XCTAssertEqual(display.subtitle, "37 of 120 · IMG_1234.HEIC")
        XCTAssertEqual(display.totalUnitCount, 120 * steps)
        XCTAssertEqual(display.completedUnitCount, 36 * steps)
    }

    func testFileProgressMovesTheBar() {
        let display = display([
            .runStarted(total: 2, totalBytes: 0),
            .unitStarted(index: 0, total: 2, fileName: "IMG_1.MOV", bytes: 1_000),
            .unitProgress(sent: 250, total: 1_000),
        ])
        XCTAssertEqual(display.completedUnitCount, steps / 4)
        XCTAssertEqual(display.subtitle, "1 of 2 · IMG_1.MOV")
    }

    func testFinishedUnitClearsTheFileName() {
        let display = display([
            .runStarted(total: 2, totalBytes: 0),
            .unitStarted(index: 0, total: 2, fileName: "IMG_1.HEIC", bytes: 10),
            .unitProgress(sent: 10, total: 10),
            .unitFinished(index: 0, total: 2, status: .done),
        ])
        XCTAssertEqual(display.subtitle, "1 of 2")
        XCTAssertEqual(display.completedUnitCount, steps)
    }

    func testResults() {
        let base: [SyncEvent] = [.runStarted(total: 3, totalBytes: 0)]
        XCTAssertEqual(display(base + [.runFinished(report(uploaded: 3))]).subtitle, "3 uploaded")
        XCTAssertEqual(display(base + [.runFinished(report(uploaded: 2, failed: 1))]).subtitle, "2 uploaded · 1 failed")
        XCTAssertEqual(display(base + [.runFinished(report(blockedBy: .cancelled))]).subtitle, "Stopped")
        XCTAssertEqual(
            display(base + [.runFinished(report(blockedBy: .expensiveNetwork))]).subtitle, "Waiting for Wi-Fi")
        XCTAssertEqual(display(base + [.runFinished(report(blockedBy: .authLost))]).subtitle, "Log in again")
    }

    func testBlockedRunDoesNotLookComplete() {
        let display = display([.runStarted(total: 4, totalBytes: 0), .runFinished(report(blockedBy: .noNetwork))])
        XCTAssertEqual(display.completedUnitCount, 0)
    }

    func testTaskSuccess() {
        XCTAssertTrue(BackgroundSync.succeeded(nil))
        XCTAssertTrue(BackgroundSync.succeeded(report(uploaded: 1)))
        XCTAssertTrue(BackgroundSync.succeeded(report(blockedBy: .deadline)))
        XCTAssertFalse(BackgroundSync.succeeded(report(blockedBy: .cancelled)))
        XCTAssertFalse(BackgroundSync.succeeded(report(blockedBy: .noNetwork)))
    }

    func testTaskIdentifiersAreFoundBySuffix() {
        let identifiers = ["io.example.app.TEAM.backfill", "io.example.app.TEAM.syncnow"]
        XCTAssertEqual(
            BackgroundSync.identifier(endingWith: ".backfill", in: identifiers), "io.example.app.TEAM.backfill")
        XCTAssertEqual(
            BackgroundSync.identifier(endingWith: ".syncnow", in: identifiers), "io.example.app.TEAM.syncnow")
        XCTAssertNil(BackgroundSync.identifier(endingWith: ".backfill", in: ["io.example.app.syncnow"]))
    }
}
