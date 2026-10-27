/// What started a sync run.
import Foundation

/// User-controlled sync options.

/// Why a sync run stopped before finishing everything.

/// Number of upload units in each state.

/// The outcome of one sync run.
public enum SyncTrigger: String, Codable, Sendable { case manual, intent, backgroundProcessing, appLaunch }
public struct SyncSettings: Codable, Sendable, Equatable {
    public var includeScreenshots: Bool
    public var resendEdits: Bool

    /// Creates settings; screenshots are included and edits are not re-sent by default.
    public init(includeScreenshots: Bool = true, resendEdits: Bool = false) {
        self.includeScreenshots = includeScreenshots
        self.resendEdits = resendEdits
    }
}
public enum BlockReason: String, Codable, Sendable {
    case noNetwork, expensiveNetwork, needsCharger, lowDisk, authLost, noLibraryAccess, deadline, cancelled
}
public struct StatusCounts: Codable, Sendable, Equatable {
    public var done: Int
    public var pending: Int
    public var uploading: Int
    public var failed: Int
    public var skipped: Int
    public var backfillPending: Int

    /// Creates counts; every count starts at zero.
    public init(
        done: Int = 0,
        pending: Int = 0,
        uploading: Int = 0,
        failed: Int = 0,
        skipped: Int = 0,
        backfillPending: Int = 0
    ) {
        self.done = done
        self.pending = pending
        self.uploading = uploading
        self.failed = failed
        self.skipped = skipped
        self.backfillPending = backfillPending
    }
}
public struct SyncReport: Codable, Sendable, Equatable {
    public var trigger: SyncTrigger
    public var startedAt: Date
    public var endedAt: Date
    public var uploaded: Int
    public var failed: Int
    public var skipped: Int
    public var remainingEligible: Int
    public var blockedBy: BlockReason?

    /// Creates a sync report.
    public init(
        trigger: SyncTrigger,
        startedAt: Date,
        endedAt: Date,
        uploaded: Int,
        failed: Int,
        skipped: Int,
        remainingEligible: Int,
        blockedBy: BlockReason? = nil
    ) {
        self.trigger = trigger
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.uploaded = uploaded
        self.failed = failed
        self.skipped = skipped
        self.remainingEligible = remainingEligible
        self.blockedBy = blockedBy
    }
}
