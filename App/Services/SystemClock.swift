import Foundation
import SyncCore

/// The real wall clock.
struct SystemClock: Clock {
    func now() -> Date {
        Date()
    }
}
