import ActivityKit
import Foundation

/// The Live Activity shown while a Shortcuts-triggered sync uploads (D12).
struct SyncActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Items handled so far while syncing; items uploaded once finished.
        var done: Int
        var total: Int
        var currentFileName: String?
        var bytesRemaining: Int64
        var uploadedBytes: Int64
        var finished: Bool
    }
}

extension SyncActivityAttributes.ContentState {
    /// How far the run is, from 0 to 1.
    var fraction: Double {
        if finished { return 1 }
        return total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0
    }

    /// "37/120" while syncing, "42" once finished.
    var compactText: String {
        finished ? "\(done)" : "\(done)/\(total)"
    }

    /// "37/120 · 1.2 GB left" while syncing, "42 uploaded · 1.3 GB" once finished.
    var summary: String {
        if finished {
            let uploaded = "\(done) uploaded"
            return uploadedBytes > 0 ? "\(uploaded) · \(Self.format(uploadedBytes))" : uploaded
        }
        let count = "\(done)/\(total)"
        return bytesRemaining > 0 ? "\(count) · \(Self.format(bytesRemaining)) left" : count
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
