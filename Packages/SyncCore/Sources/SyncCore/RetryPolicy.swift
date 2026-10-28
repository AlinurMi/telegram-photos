import Foundation

/// Decides when a failed upload is tried again, or whether it gives up.
public enum RetryPolicy {
    /// After this many attempts a unit becomes `failed`.
    public static let maxAttempts = 8

    private static let backoffSeconds: [Int] = [60, 300, 1800, 7200, 43200]

    /// When to retry after `attempts` tries (counting the one that just failed), or `nil` if the unit should become `failed`.
    /// Only `transient` and `rateLimited` errors are retried; every other kind returns `nil`.
    public static func nextAttempt(after attempts: Int, error: UploadErrorKind, now: Date) -> Date? {
        guard attempts < maxAttempts else { return nil }
        switch error {
        case .transient:
            return now.addingTimeInterval(TimeInterval(backoff(after: attempts)))
        case .rateLimited(let retryAfterSeconds):
            return now.addingTimeInterval(TimeInterval(max(retryAfterSeconds, backoff(after: attempts))))
        case .permanent, .notLocal, .tooLarge, .cancelled, .authLost:
            return nil
        }
    }

    private static func backoff(after attempts: Int) -> Int {
        let index = min(max(attempts, 1), backoffSeconds.count) - 1
        return backoffSeconds[index]
    }
}
