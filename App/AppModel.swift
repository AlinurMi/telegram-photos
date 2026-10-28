import Foundation
import Observation
import SyncCore

/// What the screens show: the state of syncing, the counts and the last result.
///
/// The coordinator feeds it. Views only read it.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable, Sendable {
        case idle
        /// `total` is 0 while the app is still looking for new photos.
        case syncing(done: Int, total: Int, fileName: String?, bytesRemaining: Int64)
        case blocked(BlockReason)
    }

    private(set) var phase: Phase = .idle
    private(set) var counts = StatusCounts()
    private(set) var lastSyncAt: Date?
    private(set) var lastReport: SyncReport?

    /// Set by the "Allow cellular for this sync" button; cleared when the run ends.
    var allowCellularThisRun = false

    private var total = 0
    private var done = 0
    private var totalBytes: Int64 = 0
    private var handledBytes: Int64 = 0
    private var currentBytes: Int64 = 0
    private var currentSent: Int64 = 0
    private var currentFileName: String?

    /// Whether a sync run is in progress.
    var isSyncing: Bool {
        if case .syncing = phase { return true }
        return false
    }

    /// Called when a run is accepted, before the engine reports anything.
    func runBegan() {
        total = 0
        done = 0
        totalBytes = 0
        handledBytes = 0
        currentBytes = 0
        currentSent = 0
        currentFileName = nil
        publishProgress()
    }

    /// Updates the progress from one engine event.
    func apply(_ event: SyncEvent) {
        switch event {
        case .runStarted(let total, let totalBytes):
            self.total = total
            self.totalBytes = totalBytes
            publishProgress()
        case .unitStarted(let index, let total, let fileName, let bytes):
            done = index
            self.total = total
            currentFileName = fileName
            currentBytes = bytes ?? 0
            currentSent = 0
            publishProgress()
        case .unitProgress(let sent, _):
            currentSent = sent
            publishProgress()
        case .unitFinished(let index, let total, _):
            // A unit that failed or was skipped won't be sent, so its bytes no longer count as remaining.
            done = index + 1
            self.total = total
            handledBytes += currentBytes
            currentBytes = 0
            currentSent = 0
            currentFileName = nil
            publishProgress()
        case .runFinished(let report):
            lastReport = report
            allowCellularThisRun = false
            phase = Self.phase(after: report)
        }
    }

    /// Replaces the numbers shown on the status screen.
    func update(counts: StatusCounts, lastSyncAt: Date?) {
        self.counts = counts
        self.lastSyncAt = lastSyncAt
    }

    /// Shows a report saved by an earlier launch, unless a newer one is already there.
    func restore(report: SyncReport) {
        if lastReport == nil { lastReport = report }
    }

    /// Forgets the last report (after a reset).
    func clearReport() {
        lastReport = nil
    }

    /// A stop because of the clock or a cancel needs nothing from the owner, so it reads as idle.
    static func phase(after report: SyncReport) -> Phase {
        switch report.blockedBy {
        case nil, .cancelled?, .deadline?:
            return .idle
        case let reason?:
            return .blocked(reason)
        }
    }

    private func publishProgress() {
        let remaining = max(0, totalBytes - handledBytes - currentSent)
        phase = .syncing(done: done, total: total, fileName: currentFileName, bytesRemaining: remaining)
    }
}

extension AppModel: SyncObserver {
    nonisolated func handle(_ event: SyncEvent) async {
        await apply(event)
    }
}
