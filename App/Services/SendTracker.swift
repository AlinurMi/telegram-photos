import Foundation
import SyncCore

/// How one outgoing message ended, as reported by TDLib.
enum SendOutcome: Equatable, Sendable {
    case sent(messageId: Int64)
    case failed(UploadError)
}

/// Pairs each outgoing message with its result and its upload progress.
///
/// TDLib reports results through updates that can arrive before `sendMessage` has even returned,
/// so every result is kept until someone asks for it. Updates come in on TDLib's queue while
/// uploads wait on the caller's task, so all state sits behind one lock.
final class SendTracker: @unchecked Sendable {
    private struct FileWatch {
        let total: Int64
        let onProgress: @Sendable (Int64, Int64) -> Void
        var lastReported: Int64 = -1
    }

    private let lock = NSLock()
    private var buffered: [Int64: SendOutcome] = [:]
    private var waiters: [Int64: CheckedContinuation<SendOutcome, Never>] = [:]
    private var abandoned: Set<Int64> = []
    private var watches: [Int: FileWatch] = [:]

    /// Records the result for the message that was sent as `oldMessageId`. The first result wins.
    func record(_ outcome: SendOutcome, for oldMessageId: Int64) {
        let waiter: CheckedContinuation<SendOutcome, Never>? = lock.withLock {
            if abandoned.remove(oldMessageId) != nil { return nil }
            if let waiter = waiters.removeValue(forKey: oldMessageId) { return waiter }
            if buffered[oldMessageId] == nil { buffered[oldMessageId] = outcome }
            return nil
        }
        waiter?.resume(returning: outcome)
    }

    /// Waits for the result of `oldMessageId`; returns at once if it already arrived.
    func outcome(for oldMessageId: Int64) async -> SendOutcome {
        await withCheckedContinuation { continuation in
            let ready: SendOutcome? = lock.withLock {
                if let result = buffered.removeValue(forKey: oldMessageId) { return result }
                if abandoned.contains(oldMessageId) { return Self.cancelled }
                waiters[oldMessageId] = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Gives up on `oldMessageId`: a waiter ends with a cancelled result and a late TDLib result is dropped.
    /// Returns `false` if the result had already arrived, so the message must not be deleted.
    @discardableResult
    func abandon(_ oldMessageId: Int64) -> Bool {
        let (didAbandon, waiter): (Bool, CheckedContinuation<SendOutcome, Never>?) = lock.withLock {
            if buffered[oldMessageId] != nil { return (false, nil) }
            abandoned.insert(oldMessageId)
            return (true, waiters.removeValue(forKey: oldMessageId))
        }
        waiter?.resume(returning: Self.cancelled)
        return didAbandon
    }

    /// Ends every wait with `error`, for when TDLib shuts down and no more results will come.
    func failPending(with error: UploadError) {
        let pending: [CheckedContinuation<SendOutcome, Never>] = lock.withLock {
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        for waiter in pending { waiter.resume(returning: .failed(error)) }
    }

    /// Starts reporting upload progress for `fileId`, measured against `total` bytes.
    func watchFile(id fileId: Int, total: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        lock.withLock { watches[fileId] = FileWatch(total: total, onProgress: onProgress) }
    }

    /// Stops reporting progress for `fileId`.
    func unwatchFile(id fileId: Int) {
        lock.withLock { _ = watches.removeValue(forKey: fileId) }
    }

    /// Reports how many bytes of `fileId` have reached Telegram. Only forward progress is passed on.
    func fileUpdated(id fileId: Int, uploadedSize: Int64) {
        let report: (@Sendable (Int64, Int64) -> Void, Int64, Int64)? = lock.withLock {
            guard var watch = watches[fileId], uploadedSize > watch.lastReported else { return nil }
            watch.lastReported = uploadedSize
            watches[fileId] = watch
            return (watch.onProgress, min(uploadedSize, watch.total), watch.total)
        }
        if let (onProgress, sent, total) = report { onProgress(sent, total) }
    }

    private static let cancelled = SendOutcome.failed(UploadError(kind: .cancelled, message: "cancelled"))
}
