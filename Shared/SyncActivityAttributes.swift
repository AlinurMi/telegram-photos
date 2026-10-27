import ActivityKit

import Foundation

struct SyncActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var done: Int
        var total: Int
        var currentFileName: String?
        var bytesRemaining: Int64
        var uploadedBytes: Int64
        var finished: Bool
    }
}
