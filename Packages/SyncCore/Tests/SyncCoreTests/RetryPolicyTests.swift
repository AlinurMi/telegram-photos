import Foundation

import Testing

@testable import SyncCore

private let now = Date(timeIntervalSince1970: 1_000_000)
@Test(arguments: [(1, 60.0), (2, 300.0), (3, 1800.0), (4, 7200.0), (5, 43200.0), (6, 43200.0), (7, 43200.0)])
func transientBackoffSteps(attempts: Int, seconds: Double) {
    let next = RetryPolicy.nextAttempt(after: attempts, error: .transient, now: now)
    #expect(next == now.addingTimeInterval(seconds))
}
@Test func maxAttemptsIsEight() {
    #expect(RetryPolicy.maxAttempts == 8)
}
@Test func reachingMaxAttemptsFails() {
    #expect(RetryPolicy.nextAttempt(after: 7, error: .transient, now: now) != nil)
    #expect(RetryPolicy.nextAttempt(after: 8, error: .transient, now: now) == nil)
    #expect(RetryPolicy.nextAttempt(after: 9, error: .transient, now: now) == nil)
}
@Test func zeroOrNegativeAttemptsUseFirstStep() {
    #expect(RetryPolicy.nextAttempt(after: 0, error: .transient, now: now) == now.addingTimeInterval(60))
    #expect(RetryPolicy.nextAttempt(after: -3, error: .transient, now: now) == now.addingTimeInterval(60))
}
@Test func rateLimitLongerThanBackoffWins() {
    let next = RetryPolicy.nextAttempt(after: 1, error: .rateLimited(retryAfterSeconds: 600), now: now)
    #expect(next == now.addingTimeInterval(600))
}
@Test func rateLimitShorterThanBackoffUsesBackoff() {
    let next = RetryPolicy.nextAttempt(after: 2, error: .rateLimited(retryAfterSeconds: 10), now: now)
    #expect(next == now.addingTimeInterval(300))
}
@Test func rateLimitEqualToBackoff() {
    let next = RetryPolicy.nextAttempt(after: 1, error: .rateLimited(retryAfterSeconds: 60), now: now)
    #expect(next == now.addingTimeInterval(60))
}
@Test func rateLimitStillFailsAtMaxAttempts() {
    let error = UploadErrorKind.rateLimited(retryAfterSeconds: 30)
    #expect(RetryPolicy.nextAttempt(after: 8, error: error, now: now) == nil)
}
@Test func negativeRateLimitFallsBackToBackoff() {
    let next = RetryPolicy.nextAttempt(after: 1, error: .rateLimited(retryAfterSeconds: -5), now: now)
    #expect(next == now.addingTimeInterval(60))
}
@Test(arguments: [UploadErrorKind.permanent, .notLocal, .tooLarge, .cancelled, .authLost])
func nonRetryableKindsReturnNil(kind: UploadErrorKind) {
    #expect(RetryPolicy.nextAttempt(after: 1, error: kind, now: now) == nil)
}
