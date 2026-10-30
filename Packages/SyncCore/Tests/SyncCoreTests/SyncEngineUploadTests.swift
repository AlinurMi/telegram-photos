import Foundation
import Testing

@testable import SyncCore

private let start = Date(timeIntervalSince1970: 1_790_000_000)

/// Cancels the task that is running the sync, then reports the cancellation the way the real uploader would.
private actor CancellingUploader: TelegramUploader {
    let throwing: Bool
    private(set) var sendCount = 0

    init(throwing: Bool) { self.throwing = throwing }

    func maxFileSize() async -> Int64 { 2_000_000_000 }

    func sendDocument(
        fileURL: URL,
        caption: Caption,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Int64 {
        sendCount += 1
        withUnsafeCurrentTask { $0?.cancel() }
        if throwing { throw UploadError(kind: .cancelled, message: "cancelled") }
        return 42
    }

    func findMessage(assetTag: String, role: UnitRole) async throws -> Int64? { nil }

    nonisolated func allDocumentCaptions() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct Harness {
    let library = FakePhotoLibrary()
    let uploader = FakeUploader()
    let store = InMemoryStateStore()
    let environment = FakeEnvironment()
    let places = FakePlaceResolver()
    let clock = FixedClock(start)
    let observer = RecordingObserver()
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("upload-tests-\(UUID().uuidString)")

    func engine(uploader override: (any TelegramUploader)? = nil, observing: Bool = false) -> SyncEngine {
        SyncEngine(
            library: library,
            uploader: override ?? uploader,
            store: store,
            environment: environment,
            places: places,
            clock: clock,
            timeZone: TimeZone(identifier: "UTC") ?? .current,
            workDirectory: workDirectory,
            observer: observing ? observer : nil
        )
    }

    /// Photos created after the baseline, so they are not backfill. `seconds` orders them.
    func addPhotos(
        _ ids: [String], at seconds: [Double]? = nil, location: Coordinate? = nil, filenameBase: String? = nil
    ) async {
        var assets = await library.assets
        for (offset, id) in ids.enumerated() {
            assets.append(
                AssetDescriptor(
                    localIdentifier: id,
                    creationDate: start.addingTimeInterval(seconds?[offset] ?? Double(offset + 1)),
                    mediaKind: .image,
                    location: location,
                    resources: [
                        ResourceDescriptor(kind: .photo, originalFilename: "\(filenameBase ?? id).HEIC", byteSize: 1234)
                    ]
                ))
        }
        await library.setAssets(assets)
    }

    func unit(_ id: String) async throws -> UploadUnit {
        try #require(try await store.allUnits().first { $0.assetLocalIdentifier == id })
    }

    func workDirectoryIsEmpty() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)) ?? []).isEmpty
    }
}

private func request(
    trigger: SyncTrigger = .manual, deadline: Date? = nil, allowCellular: Bool = false,
    settings: SyncSettings = SyncSettings()
) -> SyncRequest {
    SyncRequest(trigger: trigger, deadline: deadline, allowCellular: allowCellular, settings: settings)
}

@Test func happyPathUploadsInOrderAndStoresMessageIds() async throws {
    let h = Harness()
    await h.addPhotos(["b", "a", "c"], at: [20, 10, 30])
    _ = try await h.engine().discover(settings: SyncSettings())
    h.clock.advance(by: 100)

    let report = await h.engine().runOnce(request())

    #expect(report.uploaded == 3)
    #expect(report.failed == 0 && report.skipped == 0)
    #expect(report.remainingEligible == 0)
    #expect(report.blockedBy == nil)
    let sent = await h.uploader.sent.map { $0.fileURL.lastPathComponent }
    #expect(sent == ["a.HEIC", "b.HEIC", "c.HEIC"])
    let a = try await h.unit("a")
    let b = try await h.unit("b")
    let c = try await h.unit("c")
    #expect([a.messageId, b.messageId, c.messageId] == [1001, 1002, 1003])
    #expect([a.status, b.status, c.status] == [.done, .done, .done])
    #expect(a.uploadedAt == start.addingTimeInterval(100))
    #expect(try await h.store.meta(.lastSuccessfulSyncAt) == ISO8601DateFormatter().string(from: a.uploadedAt!))
}

@Test func firstRunDiscoversByItself() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    let report = await h.engine().runOnce(request())
    #expect(report.uploaded == 1)
}

@Test func workDirectoryIsEmptyAfterwards() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b/c|d"])
    await h.library.setExportError(UploadError(kind: .notLocal, message: "icloud"), for: "b/c|d")
    _ = await h.engine().runOnce(request())
    #expect(h.workDirectoryIsEmpty())
}

@Test func exportedFileIsSentFromPerUnitDirectory() async throws {
    let h = Harness()
    await h.addPhotos(["x/y|z"], filenameBase: "photo")
    _ = await h.engine().runOnce(request())
    let url = try #require(await h.uploader.sent.first?.fileURL)
    #expect(url.deletingLastPathComponent().lastPathComponent == "x_y_z_primary")
    #expect(await h.uploader.sent.first?.byteCount == 16)
}

@Test func notLocalIsSkipped() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    await h.library.setExportError(UploadError(kind: .notLocal, message: "icloud"), for: "a")
    let report = await h.engine().runOnce(request())
    #expect(report.uploaded == 1)
    #expect(report.skipped == 1)
    let a = try await h.unit("a")
    #expect(a.status == .skipped)
    #expect(a.skipReason == .notLocal)
    #expect(a.attempts == 0)
}

@Test func tooLargeIsSkippedAndNeverExported() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.uploader.setMaxSize(1000)
    let report = await h.engine().runOnce(request())
    #expect(report.skipped == 1 && report.uploaded == 0)
    let a = try await h.unit("a")
    #expect(a.status == .skipped)
    #expect(a.skipReason == .tooLarge)
    #expect(await h.library.exports.isEmpty)
}

@Test func tooLargeFromUploaderIsSkipped() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.uploader.script(send: .failure(UploadError(kind: .tooLarge, message: "big")))
    let report = await h.engine().runOnce(request())
    #expect(report.skipped == 1)
    #expect(try await h.unit("a").skipReason == .tooLarge)
}

@Test func transientErrorBacksOffAndIsNotRetriedEarly() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.uploader.script(send: .failure(UploadError(kind: .transient, message: "network hiccup")))

    let first = await h.engine().runOnce(request())
    #expect(first.uploaded == 0 && first.failed == 0)
    var a = try await h.unit("a")
    #expect(a.status == .pending)
    #expect(a.attempts == 1)
    #expect(a.lastError == "network hiccup")
    #expect(a.nextAttemptAt == start.addingTimeInterval(60))
    #expect(first.remainingEligible == 0)

    h.clock.advance(by: 30)
    let early = await h.engine().runOnce(request())
    #expect(early.uploaded == 0)
    #expect(await h.uploader.sent.count == 1)

    h.clock.advance(by: 31)
    let later = await h.engine().runOnce(request())
    #expect(later.uploaded == 1)
    a = try await h.unit("a")
    #expect(a.status == .done)
    #expect(a.lastError == nil)
}

@Test func eightFailuresMakeTheUnitFailed() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    for _ in 0..<8 {
        await h.uploader.script(send: .failure(UploadError(kind: .transient, message: "nope")))
    }
    var reports: [SyncReport] = []
    for _ in 0..<8 {
        reports.append(await h.engine().runOnce(request()))
        h.clock.advance(by: 100_000)
    }
    let a = try await h.unit("a")
    #expect(a.status == .failed)
    #expect(a.attempts == 8)
    #expect(a.nextAttemptAt == nil)
    #expect(reports.map(\.failed) == [0, 0, 0, 0, 0, 0, 0, 1])
    let again = await h.engine().runOnce(request())
    #expect(again.uploaded == 0)
    #expect(await h.uploader.sent.count == 8)
}

@Test func permanentErrorFailsImmediately() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.uploader.script(send: .failure(UploadError(kind: .permanent, message: "rejected")))
    let report = await h.engine().runOnce(request())
    #expect(report.failed == 1)
    let a = try await h.unit("a")
    #expect(a.status == .failed)
    #expect(a.attempts == 1)
    #expect(a.lastError == "rejected")
}

@Test func rateLimitWaitsAtLeastTheRequestedTime() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    await h.uploader.script(send: .failure(UploadError(kind: .rateLimited(retryAfterSeconds: 600), message: "slow")))
    await h.uploader.script(send: .failure(UploadError(kind: .rateLimited(retryAfterSeconds: 10), message: "slow")))
    _ = await h.engine().runOnce(request())
    #expect(try await h.unit("a").nextAttemptAt == start.addingTimeInterval(600))
    #expect(try await h.unit("b").nextAttemptAt == start.addingTimeInterval(60))
}

@Test func unknownErrorsCountAsTransient() async throws {
    struct Odd: Error {}
    let h = Harness()
    await h.addPhotos(["a"])
    let engine = h.engine(uploader: ThrowingUploader(error: Odd()))
    _ = await engine.runOnce(request())
    let a = try await h.unit("a")
    #expect(a.status == .pending)
    #expect(a.attempts == 1)
    #expect(a.nextAttemptAt == start.addingTimeInterval(60))
}

@Test func cancellationDuringSendReturnsUnitToPendingWithoutAnAttempt() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    let uploader = CancellingUploader(throwing: true)
    let engine = h.engine(uploader: uploader)
    let report = await Task { await engine.runOnce(request()) }.value
    #expect(report.blockedBy == .cancelled)
    #expect(report.uploaded == 0)
    let a = try await h.unit("a")
    #expect(a.status == .pending)
    #expect(a.attempts == 0)
    #expect(a.nextAttemptAt == nil)
    #expect(try await h.unit("b").status == .pending)
    #expect(await uploader.sendCount == 1)
    #expect(h.workDirectoryIsEmpty())
}

@Test func cancellationBetweenUnitsStopsBeforeTheNext() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    let uploader = CancellingUploader(throwing: false)
    let engine = h.engine(uploader: uploader)
    let report = await Task { await engine.runOnce(request()) }.value
    #expect(report.blockedBy == .cancelled)
    #expect(report.uploaded == 1)
    #expect(report.remainingEligible == 1)
    #expect(try await h.unit("a").status == .done)
    #expect(try await h.unit("b").status == .pending)
    #expect(await uploader.sendCount == 1)
}

@Test func deadlineStopsBeforeStartingTheNextUnit() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    // The first unit starts well before the deadline, but its upload takes 3 s, which leaves less than the 5 s margin.
    let uploader = ClockAdvancingUploader(clock: h.clock, seconds: 3)
    let engine = h.engine(uploader: uploader)
    let report = await engine.runOnce(request(deadline: start.addingTimeInterval(7)))
    #expect(report.uploaded == 1)
    #expect(report.blockedBy == .deadline)
    #expect(report.remainingEligible == 1)
    #expect(try await h.unit("b").status == .pending)
}

@Test func deadlineInsideTheMarginStopsImmediately() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    let report = await h.engine().runOnce(request(deadline: start.addingTimeInterval(4)))
    #expect(report.blockedBy == .deadline)
    #expect(report.uploaded == 0)
    #expect(await h.uploader.sent.isEmpty)
}

@Test func expensiveNetworkBlocksUnlessCellularIsAllowed() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.environment.setNetwork(.expensive)

    let blocked = await h.engine().runOnce(request())
    #expect(blocked.blockedBy == .expensiveNetwork)
    #expect(blocked.uploaded == 0)
    #expect(blocked.remainingEligible == 1)
    // Discovery still ran.
    #expect(try await h.unit("a").status == .pending)

    let allowed = await h.engine().runOnce(request(allowCellular: true))
    #expect(allowed.blockedBy == nil)
    #expect(allowed.uploaded == 1)
}

@Test func noNetworkBlocksAndStillDiscovers() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.environment.setNetwork(.unavailable)
    let report = await h.engine().runOnce(request())
    #expect(report.blockedBy == .noNetwork)
    #expect(try await h.store.allUnits().count == 1)
}

@Test func lowDiskStopsTheRun() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.environment.setFreeDisk(1234 + 200 * 1024 * 1024 - 1)
    let blocked = await h.engine().runOnce(request())
    #expect(blocked.blockedBy == .lowDisk)
    #expect(try await h.unit("a").status == .pending)
    #expect(await h.library.exports.isEmpty)

    await h.environment.setFreeDisk(1234 + 200 * 1024 * 1024)
    let fine = await h.engine().runOnce(request())
    #expect(fine.uploaded == 1)
}

@Test func missingLibraryAccessBlocksTheRun() async throws {
    let h = Harness()
    await h.library.setAuthorization(.limited)
    let report = await h.engine().runOnce(request())
    #expect(report.blockedBy == .noLibraryAccess)
    #expect(report.uploaded == 0)
}

@Test func backfillWaitsForTheCharger() async throws {
    let h = Harness()
    await h.environment.setCharging(false)
    await h.library.setAssets([
        AssetDescriptor(
            localIdentifier: "old", creationDate: start.addingTimeInterval(-500), mediaKind: .image,
            resources: [ResourceDescriptor(kind: .photo, originalFilename: "old.HEIC", byteSize: 10)])
    ])
    let waiting = await h.engine().runOnce(request(trigger: .intent))
    #expect(waiting.blockedBy == .needsCharger)
    #expect(waiting.uploaded == 0)
    #expect(waiting.remainingEligible == 0)

    await h.environment.setCharging(true)
    let charging = await h.engine().runOnce(request(trigger: .intent))
    #expect(charging.blockedBy == nil)
    #expect(charging.uploaded == 1)
}

@Test func syncNowUploadsBackfillWithoutTheCharger() async throws {
    let h = Harness()
    await h.environment.setCharging(false)
    await h.library.setAssets([
        AssetDescriptor(
            localIdentifier: "old", creationDate: start.addingTimeInterval(-500), mediaKind: .image,
            resources: [ResourceDescriptor(kind: .photo, originalFilename: "old.HEIC", byteSize: 10)])
    ])
    let report = await h.engine().runOnce(request(trigger: .manual))
    #expect(report.blockedBy == nil)
    #expect(report.uploaded == 1)
    #expect(report.remainingEligible == 0)
}

@Test func automaticRunsStillLeaveBackfillWhenUnplugged() async throws {
    for trigger in [SyncTrigger.intent, .backgroundProcessing, .appLaunch] {
        let h = Harness()
        await h.environment.setCharging(false)
        await h.library.setAssets([
            AssetDescriptor(
                localIdentifier: "old", creationDate: start.addingTimeInterval(-500), mediaKind: .image,
                resources: [ResourceDescriptor(kind: .photo, originalFilename: "old.HEIC", byteSize: 10)])
        ])
        let report = await h.engine().runOnce(request(trigger: trigger))
        #expect(report.blockedBy == .needsCharger)
        #expect(report.uploaded == 0)
    }
}

@Test func nothingToDoIsNotBlocked() async throws {
    let h = Harness()
    await h.environment.setCharging(false)
    let report = await h.engine().runOnce(request())
    #expect(report.blockedBy == nil)
    #expect(report.uploaded == 0)
}

@Test func nonBackfillUploadsWhileNotCharging() async throws {
    let h = Harness()
    await h.environment.setCharging(false)
    await h.addPhotos(["new"])
    let report = await h.engine().runOnce(request())
    #expect(report.uploaded == 1)
    #expect(report.blockedBy == nil)
}

@Test func interruptedUploadWithAMessageInTheChannelBecomesDone() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    _ = try await h.engine().discover(settings: SyncSettings())
    var a = try await h.unit("a")
    a.status = .uploading
    try await h.store.update(a)
    var b = try await h.unit("b")
    b.status = .uploading
    try await h.store.update(b)
    await h.uploader.script(find: .success(777))
    await h.uploader.script(find: .success(nil))

    let report = await h.engine().runOnce(request())

    a = try await h.unit("a")
    #expect(a.status == .done)
    #expect(a.messageId == 777)
    // The other interrupted unit had no message, so it was sent again.
    #expect(try await h.unit("b").status == .done)
    #expect(await h.uploader.sent.count == 1)
    #expect(await h.uploader.sent.first?.fileURL.lastPathComponent == "b.HEIC")
    #expect(report.uploaded == 1)
}

@Test func unknownResumeOutcomeLeavesTheUnitUploading() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    _ = try await h.engine().discover(settings: SyncSettings())
    var a = try await h.unit("a")
    a.status = .uploading
    try await h.store.update(a)
    await h.uploader.script(find: .failure(UploadError(kind: .transient, message: "offline")))

    _ = await h.engine().runOnce(request())
    #expect(try await h.unit("a").status == .uploading)
    #expect(await h.uploader.sent.isEmpty)
}

@Test func authLostDuringResumeStopsTheRun() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    _ = try await h.engine().discover(settings: SyncSettings())
    var a = try await h.unit("a")
    a.status = .uploading
    try await h.store.update(a)
    await h.uploader.script(find: .failure(UploadError(kind: .authLost, message: "logged out")))

    let report = await h.engine().runOnce(request())
    #expect(report.blockedBy == .authLost)
    #expect(await h.uploader.sent.isEmpty)
}

@Test func placeNameIsCachedPerRoundedCoordinate() async throws {
    let h = Harness()
    let first = Coordinate(latitude: 42.8741, longitude: 74.5698)
    let second = Coordinate(latitude: 42.8749, longitude: 74.5702)
    await h.places.setName("Bishkek", for: first)
    await h.library.setAssets([
        AssetDescriptor(
            localIdentifier: "a", creationDate: start.addingTimeInterval(1), mediaKind: .image, location: first,
            resources: [ResourceDescriptor(kind: .photo, originalFilename: "a.HEIC", byteSize: 10)]),
        AssetDescriptor(
            localIdentifier: "b", creationDate: start.addingTimeInterval(2), mediaKind: .image, location: second,
            resources: [ResourceDescriptor(kind: .photo, originalFilename: "b.HEIC", byteSize: 10)]),
    ])
    _ = await h.engine().runOnce(request())
    #expect(await h.places.lookups == 1)
    #expect(try await h.store.cachedPlace(key: "42.87,74.57") == "Bishkek")
    let captions = await h.uploader.sent.map(\.caption.text)
    #expect(captions.count == 2)
    #expect(captions.allSatisfy { $0.contains("Bishkek") })
}

@Test func unknownPlaceIsNotCached() async throws {
    let h = Harness()
    await h.addPhotos(["a"], location: Coordinate(latitude: 1, longitude: 2))
    _ = await h.engine().runOnce(request())
    #expect(try await h.store.cachedPlace(key: "1.00,2.00") == nil)
    #expect(await h.places.lookups == 1)
}

@Test func observerSeesTheEventSequenceForTwoUnits() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    let report = await h.engine(observing: true).runOnce(request())
    let events = await h.observer.events
    #expect(
        events == [
            .runStarted(total: 2, totalBytes: 2468),
            .unitStarted(index: 0, total: 2, fileName: "a.HEIC", bytes: 1234),
            .unitProgress(sent: 16, total: 16),
            .unitFinished(index: 0, total: 2, status: .done),
            .unitStarted(index: 1, total: 2, fileName: "b.HEIC", bytes: 1234),
            .unitProgress(sent: 16, total: 16),
            .unitFinished(index: 1, total: 2, status: .done),
            .runFinished(report),
        ])
}

@Test func authLostStopsTheRun() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    await h.uploader.script(send: .failure(UploadError(kind: .authLost, message: "logged out")))
    let report = await h.engine().runOnce(request())
    #expect(report.blockedBy == .authLost)
    #expect(report.uploaded == 0)
    let a = try await h.unit("a")
    #expect(a.status == .pending)
    #expect(a.attempts == 0)
    #expect(try await h.unit("b").status == .pending)
    #expect(await h.uploader.sent.count == 1)
}

@Test func screenshotsAreLeftOutWhenDisabled() async throws {
    let h = Harness()
    await h.library.setAssets([
        AssetDescriptor(
            localIdentifier: "shot", creationDate: start.addingTimeInterval(1), mediaKind: .image,
            isScreenshotOrRecording: true,
            resources: [ResourceDescriptor(kind: .photo, originalFilename: "shot.PNG", byteSize: 10)])
    ])
    let report = await h.engine().runOnce(request(settings: SyncSettings(includeScreenshots: false)))
    #expect(report.uploaded == 0)
    #expect(try await h.unit("shot").skipReason == .screenshotsDisabled)
}

@Test func reportIsStoredAsJSON() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    let report = await h.engine().runOnce(request())
    let json = try #require(try await h.store.meta(.lastReportJSON))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SyncReport.self, from: Data(json.utf8))
    #expect(decoded.uploaded == 1)
    #expect(decoded.trigger == .manual)
    #expect(decoded.startedAt == report.startedAt)
}

/// Fails every send with the given error.
private struct ThrowingUploader: TelegramUploader {
    let error: Error

    func maxFileSize() async -> Int64 { 2_000_000_000 }

    func sendDocument(
        fileURL: URL,
        caption: Caption,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Int64 { throw error }

    func findMessage(assetTag: String, role: UnitRole) async throws -> Int64? { nil }

    func allDocumentCaptions() -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

/// Succeeds, and moves the test clock forward as if the upload took `seconds`.
private struct ClockAdvancingUploader: TelegramUploader {
    let clock: FixedClock
    let seconds: TimeInterval

    func maxFileSize() async -> Int64 { 2_000_000_000 }

    func sendDocument(
        fileURL: URL,
        caption: Caption,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Int64 {
        clock.advance(by: seconds)
        return 1
    }

    func findMessage(assetTag: String, role: UnitRole) async throws -> Int64? { nil }

    func allDocumentCaptions() -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}
