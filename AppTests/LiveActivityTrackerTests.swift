import SyncCore

import XCTest

@testable import TelegramPhotos

final class LiveActivityTrackerTests: XCTestCase {
    private typealias State = SyncActivityAttributes.ContentState

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func report(uploaded: Int) -> SyncReport {
        SyncReport(
            trigger: .intent, startedAt: start, endedAt: start, uploaded: uploaded, failed: 0, skipped: 0,
            remainingEligible: 0)
    }

    private func state(
        done: Int, total: Int, file: String? = nil, remaining: Int64, uploadedBytes: Int64 = 0, finished: Bool = false
    ) -> State {
        State(
            done: done, total: total, currentFileName: file, bytesRemaining: remaining, uploadedBytes: uploadedBytes,
            finished: finished)
    }

    func testNothingToUploadNeverStarts() {
        var tracker = LiveActivityTracker()
        XCTAssertEqual(tracker.apply(.runStarted(total: 0, totalBytes: 0), now: at(0)), .none)
        XCTAssertFalse(tracker.isShowing)
        XCTAssertEqual(tracker.apply(.runFinished(report(uploaded: 0)), now: at(1)), .none)
        XCTAssertNil(tracker.expire())
    }

    func testEventsWithoutAStartAreIgnored() {
        var tracker = LiveActivityTracker()
        XCTAssertEqual(
            tracker.apply(.unitStarted(index: 0, total: 3, fileName: "A.HEIC", bytes: 10), now: at(5)), .none)
        XCTAssertEqual(tracker.apply(.unitFinished(index: 0, total: 3, status: .done), now: at(6)), .none)
        XCTAssertEqual(tracker.apply(.runFinished(report(uploaded: 1)), now: at(7)), .none)
    }

    func testStartShowsTheTotals() {
        var tracker = LiveActivityTracker()
        let action = tracker.apply(.runStarted(total: 120, totalBytes: 1_000), now: at(0))
        XCTAssertEqual(action, .start(state(done: 0, total: 120, remaining: 1_000)))
        XCTAssertTrue(tracker.isShowing)
    }

    func testProgressIsThrottledToEveryTwoSeconds() {
        var tracker = LiveActivityTracker()
        _ = tracker.apply(.runStarted(total: 2, totalBytes: 300), now: at(0))
        let started = tracker.apply(.unitStarted(index: 0, total: 2, fileName: "IMG_1.HEIC", bytes: 100), now: at(1))
        XCTAssertEqual(started, .none)
        let progress = tracker.apply(.unitProgress(sent: 40, total: 100), now: at(2))
        XCTAssertEqual(progress, .update(state(done: 0, total: 2, file: "IMG_1.HEIC", remaining: 260)))
        XCTAssertEqual(tracker.apply(.unitProgress(sent: 60, total: 100), now: at(3.9)), .none)
        let later = tracker.apply(.unitProgress(sent: 80, total: 100), now: at(4))
        XCTAssertEqual(later, .update(state(done: 0, total: 2, file: "IMG_1.HEIC", remaining: 220)))
    }

    func testEachFinishedItemAlwaysUpdates() {
        var tracker = LiveActivityTracker()
        _ = tracker.apply(.runStarted(total: 2, totalBytes: 300), now: at(0))
        _ = tracker.apply(.unitStarted(index: 0, total: 2, fileName: "IMG_1.HEIC", bytes: 100), now: at(0.1))
        let finished = tracker.apply(.unitFinished(index: 0, total: 2, status: .done), now: at(0.2))
        XCTAssertEqual(finished, .update(state(done: 1, total: 2, remaining: 200, uploadedBytes: 100)))
        _ = tracker.apply(.unitStarted(index: 1, total: 2, fileName: "IMG_2.MOV", bytes: 200), now: at(0.3))
        let failed = tracker.apply(.unitFinished(index: 1, total: 2, status: .failed), now: at(0.4))
        XCTAssertEqual(failed, .update(state(done: 2, total: 2, remaining: 0, uploadedBytes: 100)))
    }

    func testRunFinishedEndsWithTheUploadedCount() {
        var tracker = LiveActivityTracker()
        _ = tracker.apply(.runStarted(total: 3, totalBytes: 600), now: at(0))
        _ = tracker.apply(.unitStarted(index: 0, total: 3, fileName: "A.HEIC", bytes: 100), now: at(1))
        _ = tracker.apply(.unitFinished(index: 0, total: 3, status: .done), now: at(2))
        _ = tracker.apply(.unitStarted(index: 1, total: 3, fileName: "B.HEIC", bytes: 200), now: at(3))
        _ = tracker.apply(.unitFinished(index: 1, total: 3, status: .done), now: at(4))
        let ended = tracker.apply(.runFinished(report(uploaded: 2)), now: at(5))
        XCTAssertEqual(ended, .end(state(done: 2, total: 3, remaining: 300, uploadedBytes: 300, finished: true)))
        XCTAssertFalse(tracker.isShowing)
        XCTAssertEqual(tracker.apply(.unitFinished(index: 2, total: 3, status: .done), now: at(6)), .none)
        XCTAssertNil(tracker.expire())
    }

    func testItemSkippedBeforeStartingStillCounts() {
        var tracker = LiveActivityTracker()
        _ = tracker.apply(.runStarted(total: 2, totalBytes: 5_000), now: at(0))
        let skipped = tracker.apply(.unitFinished(index: 0, total: 2, status: .skipped), now: at(1))
        XCTAssertEqual(skipped, .update(state(done: 1, total: 2, remaining: 5_000)))
    }

    func testUnknownSizeUsesTheUploadedTotal() {
        var tracker = LiveActivityTracker()
        _ = tracker.apply(.runStarted(total: 1, totalBytes: 0), now: at(0))
        _ = tracker.apply(.unitStarted(index: 0, total: 1, fileName: "A.MOV", bytes: nil), now: at(1))
        _ = tracker.apply(.unitProgress(sent: 500, total: 500), now: at(3))
        let finished = tracker.apply(.unitFinished(index: 0, total: 1, status: .done), now: at(4))
        XCTAssertEqual(finished, .update(state(done: 1, total: 1, remaining: 0, uploadedBytes: 500)))
    }

    func testExpireEndsWhatIsShowing() {
        var tracker = LiveActivityTracker()
        _ = tracker.apply(.runStarted(total: 5, totalBytes: 500), now: at(0))
        _ = tracker.apply(.unitStarted(index: 0, total: 5, fileName: "A.HEIC", bytes: 100), now: at(1))
        _ = tracker.apply(.unitFinished(index: 0, total: 5, status: .done), now: at(2))
        _ = tracker.apply(.unitStarted(index: 1, total: 5, fileName: "B.HEIC", bytes: 100), now: at(3))
        XCTAssertEqual(
            tracker.expire(), state(done: 1, total: 5, remaining: 400, uploadedBytes: 100, finished: true))
        XCTAssertFalse(tracker.isShowing)
        XCTAssertNil(tracker.expire())
    }

    func testAbandonForgetsTheRun() {
        var tracker = LiveActivityTracker()
        _ = tracker.apply(.runStarted(total: 5, totalBytes: 500), now: at(0))
        tracker.abandon()
        XCTAssertFalse(tracker.isShowing)
        XCTAssertEqual(tracker.apply(.unitFinished(index: 0, total: 5, status: .done), now: at(3)), .none)
    }

    func testCompactAndSummaryText() {
        let bytes = { (count: Int64) in ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
        let syncing = state(done: 37, total: 120, remaining: 1_200_000_000)
        XCTAssertEqual(syncing.compactText, "37/120")
        XCTAssertEqual(syncing.summary, "37/120 · \(bytes(1_200_000_000)) left")
        XCTAssertEqual(syncing.fraction, 37.0 / 120.0, accuracy: 0.0001)

        let noBytesLeft = state(done: 3, total: 3, remaining: 0)
        XCTAssertEqual(noBytesLeft.summary, "3/3")

        let finished = state(done: 42, total: 50, remaining: 0, uploadedBytes: 1_300_000_000, finished: true)
        XCTAssertEqual(finished.compactText, "42")
        XCTAssertEqual(finished.summary, "42 uploaded · \(bytes(1_300_000_000))")
        XCTAssertEqual(finished.fraction, 1)

        let nothingUploaded = state(done: 0, total: 4, remaining: 0, finished: true)
        XCTAssertEqual(nothingUploaded.summary, "0 uploaded")
        XCTAssertEqual(state(done: 0, total: 0, remaining: 0).fraction, 0)
    }
}
