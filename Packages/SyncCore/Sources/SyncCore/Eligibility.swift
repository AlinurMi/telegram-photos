import Foundation

/// Decides which upload units may be sent now, and in what order.
public enum Eligibility {
    /// Whether `unit` can be uploaded right now.
    public static func isEligible(_ unit: UploadUnit, now: Date, charging: Bool, settings: SyncSettings) -> Bool {
        guard unit.status == .pending else { return false }
        if let next = unit.nextAttemptAt, next > now { return false }
        if unit.isBackfill && !charging { return false }
        if unit.isScreenshotOrRecording && !settings.includeScreenshots { return false }
        return true
    }

    /// Sorts units by creation date (undated first), then role (primary, raw, live, edit), then id.
    public static func ordered(_ units: [UploadUnit]) -> [UploadUnit] {
        units.sorted { lhs, rhs in
            if lhs.creationDate != rhs.creationDate {
                guard let left = lhs.creationDate else { return true }
                guard let right = rhs.creationDate else { return false }
                return left < right
            }
            let leftRank = rank(lhs.role)
            let rightRank = rank(rhs.role)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.id < rhs.id
        }
    }

    private static func rank(_ role: UnitRole) -> Int {
        switch role {
        case .primary: return 0
        case .raw: return 1
        case .live: return 2
        case .edit: return 3
        }
    }
}
