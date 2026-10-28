import Foundation

@testable import SyncCore

/// Records every send and plays back scripted results; unscripted sends succeed with increasing message ids.
actor FakeUploader: TelegramUploader {
    struct Sent: Equatable {
        var fileURL: URL
        var caption: Caption
        var byteCount: Int64
    }

    var maxSize: Int64
    var captions: [String]
    private(set) var sent: [Sent] = []
    private var scriptedSends: [Result<Int64, UploadError>] = []
    private var scriptedFinds: [Result<Int64?, UploadError>] = []
    private var captionsError: UploadError?
    private var nextMessageId: Int64 = 1000

    init(maxSize: Int64 = 2_000_000_000, captions: [String] = []) {
        self.maxSize = maxSize
        self.captions = captions
    }

    func setMaxSize(_ size: Int64) { maxSize = size }
    func setCaptions(_ captions: [String]) { self.captions = captions }
    func setCaptionsError(_ error: UploadError?) { captionsError = error }

    /// Queues the result of the next `sendDocument` call.
    func script(send result: Result<Int64, UploadError>) { scriptedSends.append(result) }

    /// Queues the result of the next `findMessage` call; unscripted calls return `nil`.
    func script(find result: Result<Int64?, UploadError>) { scriptedFinds.append(result) }

    func maxFileSize() async -> Int64 { maxSize }

    func sendDocument(
        fileURL: URL,
        caption: Caption,
        progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void
    ) async throws -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        sent.append(Sent(fileURL: fileURL, caption: caption, byteCount: size))
        progress(size, size)
        if !scriptedSends.isEmpty {
            return try scriptedSends.removeFirst().get()
        }
        nextMessageId += 1
        return nextMessageId
    }

    func findMessage(assetTag: String, role: UnitRole) async throws -> Int64? {
        guard !scriptedFinds.isEmpty else { return nil }
        return try scriptedFinds.removeFirst().get()
    }

    nonisolated func allDocumentCaptions() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let captions = await self.captions
                let error = await self.captionsError
                for caption in captions { continuation.yield(caption) }
                continuation.finish(throwing: error)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
