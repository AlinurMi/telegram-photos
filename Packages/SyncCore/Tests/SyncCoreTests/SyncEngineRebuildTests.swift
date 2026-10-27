import Foundation
import Testing

@testable import SyncCore

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private struct Harness {
    let library: FakePhotoLibrary
    let uploader = FakeUploader()
    let store = InMemoryStateStore()
    let clock = FixedClock(start)
    let engine: SyncEngine

    init(authorization: LibraryAuthorization = .full) {
        library = FakePhotoLibrary(authorization: authorization)
        engine = SyncEngine(
            library: library,
            uploader: uploader,
            store: store,
            environment: FakeEnvironment(),
            places: FakePlaceResolver(),
            clock: clock,
            timeZone: TimeZone(identifier: "UTC") ?? .current,
            workDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("rebuild-tests-\(UUID().uuidString)"),
            observer: nil
        )
    }

    func addPhotos(_ ids: [String]) async {
        let assets = ids.map { id in
            AssetDescriptor(
                localIdentifier: id,
                creationDate: start.addingTimeInterval(-100),
                mediaKind: .image,
                resources: [ResourceDescriptor(kind: .photo, originalFilename: "\(id).HEIC", byteSize: 10)]
            )
        }
        await library.setAssets(assets)
    }

    func unit(_ id: String) async throws -> UploadUnit {
        try #require(try await store.allUnits().first { $0.id == id })
    }
}
private func caption(for id: String, role: String = "") -> String {
    "2026-01-02 10:00 · \(id).HEIC\n#y2026 #m01 #\(AssetTag.make(localIdentifier: id))\(role)"
}
private func failedUnit(_ id: String, status: UnitStatus = .failed) -> UploadUnit {
    UploadUnit(
        id: "\(id)|primary", assetLocalIdentifier: id, assetTag: AssetTag.make(localIdentifier: id),
        role: .primary, resourceKind: .photo, uploadFilename: "\(id).HEIC", status: status,
        attempts: 8, nextAttemptAt: start.addingTimeInterval(500), lastError: "boom")
}
@Test func rebuildMarksUnitsWithMatchingCaptionsAsDone() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b", "c"])
    await h.uploader.setCaptions([caption(for: "a"), caption(for: "c")])
    let changed = try await h.engine.rebuildFromChannel()
    #expect(changed == 2)
    #expect(try await h.unit("a|primary").status == .done)
    #expect(try await h.unit("b|primary").status == .pending)
    #expect(try await h.unit("c|primary").status == .done)
}
@Test func rebuildLeavesMessageIdEmpty() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.uploader.setCaptions([caption(for: "a")])
    _ = try await h.engine.rebuildFromChannel()
    #expect(try await h.unit("a|primary").messageId == nil)
}
@Test func rebuildMatchesTheRoleToo() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    _ = try await h.engine.discover(settings: SyncSettings())
    try await h.store.insert([
        UploadUnit(
            id: "a|raw", assetLocalIdentifier: "a", assetTag: AssetTag.make(localIdentifier: "a"), role: .raw,
            resourceKind: .alternatePhoto, uploadFilename: "a.DNG")
    ])
    await h.uploader.setCaptions([caption(for: "a")])
    let changed = try await h.engine.rebuildFromChannel()
    #expect(changed == 1)
    #expect(try await h.unit("a|primary").status == .done)
    #expect(try await h.unit("a|raw").status == .pending)

    await h.uploader.setCaptions([caption(for: "a", role: " #raw")])
    #expect(try await h.engine.rebuildFromChannel() == 1)
    #expect(try await h.unit("a|raw").status == .done)
}
@Test func rebuildCountsAUnitOnceWhenItsCaptionAppearsTwice() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.uploader.setCaptions([caption(for: "a"), caption(for: "a")])
    #expect(try await h.engine.rebuildFromChannel() == 1)
}
@Test func rebuildDoesNotCountUnitsThatAreAlreadyDone() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    _ = try await h.engine.discover(settings: SyncSettings())
    var done = try await h.unit("a|primary")
    done.status = .done
    done.messageId = 77
    try await h.store.update(done)
    await h.uploader.setCaptions([caption(for: "a"), caption(for: "b")])
    #expect(try await h.engine.rebuildFromChannel() == 1)
    #expect(try await h.unit("a|primary").messageId == 77)
}
@Test func rebuildClearsSkipAndErrorDetails() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    _ = try await h.engine.discover(settings: SyncSettings())
    var skipped = try await h.unit("a|primary")
    skipped.status = .skipped
    skipped.skipReason = .notLocal
    try await h.store.update(skipped)
    var failed = try await h.unit("b|primary")
    failed.status = .failed
    failed.attempts = 8
    failed.lastError = "boom"
    failed.nextAttemptAt = start
    try await h.store.update(failed)
    await h.uploader.setCaptions([caption(for: "a"), caption(for: "b")])
    #expect(try await h.engine.rebuildFromChannel() == 2)
    for id in ["a|primary", "b|primary"] {
        let unit = try await h.unit(id)
        #expect(unit.status == .done)
        #expect(unit.skipReason == nil)
        #expect(unit.lastError == nil)
        #expect(unit.nextAttemptAt == nil)
    }
}
@Test func rebuildIgnoresCaptionsThatDoNotMatchAnything() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.uploader.setCaptions(["", "hello", caption(for: "someone-else"), "#a0123456789 #A0123456789"])
    #expect(try await h.engine.rebuildFromChannel() == 0)
    #expect(try await h.unit("a|primary").status == .pending)
}
@Test func rebuildDiscoversNewAssetsFirst() async throws {
    let h = Harness()
    await h.addPhotos(["a"])
    await h.uploader.setCaptions([caption(for: "a")])
    #expect(try await h.store.allUnits().isEmpty)
    #expect(try await h.engine.rebuildFromChannel() == 1)
    #expect(try await h.store.allUnits().count == 1)
}
@Test func rebuildThrowsWithoutLibraryAccess() async throws {
    let h = Harness(authorization: .limited)
    await h.uploader.setCaptions([caption(for: "a")])
    await #expect(throws: UploadError.self) { _ = try await h.engine.rebuildFromChannel() }
}
@Test func rebuildChangesNothingIfReadingTheChannelFails() async throws {
    let h = Harness()
    await h.addPhotos(["a", "b"])
    await h.uploader.setCaptions([caption(for: "a")])
    await h.uploader.setCaptionsError(UploadError(kind: .transient, message: "offline"))
    await #expect(throws: UploadError.self) { _ = try await h.engine.rebuildFromChannel() }
    #expect(try await h.store.allUnits().allSatisfy { $0.status == .pending })
}
@Test func retryFailedResetsOnlyFailedUnits() async throws {
    let h = Harness()
    try await h.store.insert([
        failedUnit("a"), failedUnit("b", status: .pending), failedUnit("c", status: .done), failedUnit("d"),
    ])
    #expect(try await h.engine.retryFailed() == 2)
    for id in ["a", "d"] {
        let unit = try await h.unit("\(id)|primary")
        #expect(unit.status == .pending)
        #expect(unit.attempts == 0)
        #expect(unit.nextAttemptAt == nil)
    }
    #expect(try await h.unit("b|primary").attempts == 8)
    #expect(try await h.unit("c|primary").status == .done)
}
@Test func retryFailedReturnsZeroWhenNothingFailed() async throws {
    let h = Harness()
    #expect(try await h.engine.retryFailed() == 0)
}
