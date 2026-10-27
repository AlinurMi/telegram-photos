import Foundation

/// The real wall clock.
import SyncCore

struct SystemClock: Clock {
    func now() -> Date {
        Date()
    }
}
