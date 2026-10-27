import SyncCore

import XCTest

@testable import TelegramPhotos

@MainActor
final class AppModelTests: XCTestCase {
    func testProgressTracksFilesAndBytes() {
        let model = AppModel()
        model.runBegan()
        XCTAssertEqual(model.phase, .syncing(done: 0, total: 0, fileName: nil, bytesRemaining: 0))

        model.apply(.runStarted(total: 3, totalBytes: 300))
        XCTAssertEqual(model.phase, .syncing(done: 0, total: 3, fileName: nil, bytesRemaining: 300))

        model.apply(.unitStarted(index: 0, total: 3, fileName: "a.heic", bytes: 100))
        model.apply(.unitProgress(sent: 40, total: 100))
        XCTAssertEqual(model.phase, .syncing(done: 0, total: 3, fileName: "a.heic", bytesRemaining: 260))

        model.apply(.unitFinished(index: 0, total: 3, status: .done))
        XCTAssertEqual(model.phase, .syncing(done: 1, total: 3, fileName: nil, bytesRemaining: 200))

        // A failed unit won't be sent, so its bytes stop counting as remaining.
        model.apply(.unitStarted(index: 1, total: 3, fileName: "b.heic", bytes: 100))
        model.apply(.unitFinished(index: 1, total: 3, status: .failed))
        XCTAssertEqual(model.phase, .syncing(done: 2, total: 3, fileName: nil, bytesRemaining: 100))
    }

    func testRunFinishedStoresTheReportAndClearsTheCellularFlag() {
        let model = AppModel()
        model.allowCellularThisRun = true
        let report = SyncReport(
            trigger: .manual, startedAt: Date(), endedAt: Date(),
            uploaded: 2, failed: 0, skipped: 0, remainingEligible: 5, blockedBy: .expensiveNetwork)

        model.apply(.runFinished(report))

        XCTAssertEqual(model.lastReport, report)
        XCTAssertFalse(model.allowCellularThisRun)
        XCTAssertEqual(model.phase, .blocked(.expensiveNetwork))
    }

    func testPhaseAfterReport() {
        func phase(_ reason: BlockReason?) -> AppModel.Phase {
            let report = SyncReport(
                trigger: .manual, startedAt: Date(), endedAt: Date(),
                uploaded: 0, failed: 0, skipped: 0, remainingEligible: 0, blockedBy: reason)
            return AppModel.phase(after: report)
        }
        XCTAssertEqual(phase(nil), .idle)
        XCTAssertEqual(phase(.cancelled), .idle)
        XCTAssertEqual(phase(.deadline), .idle)
        XCTAssertEqual(phase(.noNetwork), .blocked(.noNetwork))
        XCTAssertEqual(phase(.needsCharger), .blocked(.needsCharger))
        XCTAssertEqual(phase(.authLost), .blocked(.authLost))
    }

    func testRestoredReportNeverReplacesANewerOne() {
        let model = AppModel()
        let old = SyncReport(
            trigger: .manual, startedAt: Date(), endedAt: Date(),
            uploaded: 1, failed: 0, skipped: 0, remainingEligible: 0)
        let newer = SyncReport(
            trigger: .intent, startedAt: Date(), endedAt: Date(),
            uploaded: 9, failed: 0, skipped: 0, remainingEligible: 0)

        model.restore(report: old)
        XCTAssertEqual(model.lastReport, old)
        model.apply(.runFinished(newer))
        model.restore(report: old)
        XCTAssertEqual(model.lastReport, newer)
    }
}
final class AppSettingsTests: XCTestCase {
    private func makeSettings() throws -> (AppSettings, UserDefaults) {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return (AppSettings(defaults: defaults), defaults)
    }

    func testDefaults() throws {
        let (settings, _) = try makeSettings()
        XCTAssertTrue(settings.includeScreenshots)
        XCTAssertFalse(settings.resendEdits)
        XCTAssertFalse(settings.setupCompleted)
        XCTAssertNil(settings.destinationChatId)
        XCTAssertNil(settings.destinationTitle)
        XCTAssertEqual(settings.syncSettings, SyncSettings(includeScreenshots: true, resendEdits: false))
    }

    func testValuesAreKept() throws {
        let (settings, defaults) = try makeSettings()
        settings.includeScreenshots = false
        settings.resendEdits = true
        settings.setupCompleted = true
        settings.destinationChatId = -1_001_234_567_890
        settings.destinationTitle = "Backup"

        let again = AppSettings(defaults: defaults)
        XCTAssertFalse(again.includeScreenshots)
        XCTAssertTrue(again.resendEdits)
        XCTAssertTrue(again.setupCompleted)
        XCTAssertEqual(again.destinationChatId, -1_001_234_567_890)
        XCTAssertEqual(again.destinationTitle, "Backup")
        XCTAssertEqual(again.syncSettings, SyncSettings(includeScreenshots: false, resendEdits: true))

        again.destinationChatId = nil
        again.destinationTitle = nil
        XCTAssertNil(again.destinationChatId)
        XCTAssertNil(again.destinationTitle)
    }

    func testDestinationUsesTheSameKeysAsTelegramService() throws {
        let (settings, defaults) = try makeSettings()
        defaults.set(42, forKey: TelegramService.destinationChatIdKey)
        defaults.set("Saved Messages", forKey: TelegramService.destinationTitleKey)
        XCTAssertEqual(settings.destinationChatId, 42)
        XCTAssertEqual(settings.destinationTitle, "Saved Messages")
    }
}
