import Foundation
import Testing

@testable import SyncCore

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private struct Harness {
    let library: FakePhotoLibrary
    let store: InMemoryStateStore
    let clock: FixedClock
    let engine: SyncEngine

    init(authorization: LibraryAuthorization = .full) {
        library = FakePhotoLibrary(authorization: authorization)
        store = InMemoryStateStore()
        clock = FixedClock(start)
        engine = SyncEngine(
            library: library,
            uploader: FakeUploader(),
            store: store,
            environment: FakeEnvironment(),
            places: FakePlaceResolver(),
            clock: clock,
            timeZone: TimeZone(identifier: "UTC") ?? .current,
            workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("discovery-tests"),
            observer: nil
        )
    }
}
private func photo(
    _ id: String,
    created: Date? = nil,
    screenshot: Bool = false,
    location: Coordinate? = nil,
    resources: [ResourceDescriptor]? = nil
) -> AssetDescriptor {
    AssetDescriptor(
        localIdentifier: id,
        creationDate: created,
        mediaKind: .image,
        isScreenshotOrRecording: screenshot,
        location: location,
        resources: resources ?? [ResourceDescriptor(kind: .photo, originalFilename: "\(id).HEIC", byteSize: 1234)]
    )
}
@Test func firstDiscoveryStoresBaselineAsNow() async throws {
    let h = Harness()
    _ = try await h.engine.discover(settings: SyncSettings())
    let stored = try #require(try await h.store.meta(.baselineDate))
    let parsed = try #require(ISO8601DateFormatter().date(from: stored))
    #expect(parsed == start)
}
@Test func existingBaselineIsKept() async throws {
    let h = Harness()
    try await h.store.setMeta(.baselineDate, "2020-01-01T00:00:00Z")
    h.clock.advance(by: 1000)
    _ = try await h.engine.discover(settings: SyncSettings())
    #expect(try await h.store.meta(.baselineDate) == "2020-01-01T00:00:00Z")
}
@Test func oldAssetsAreBackfillAndNewOnesAreNot() async throws {
    let h = Harness()
    await h.library.setAssets([
        photo("old", created: start.addingTimeInterval(-100)),
        photo("undated"),
        photo("new", created: start.addingTimeInterval(100)),
    ])
    let added = try await h.engine.discover(settings: SyncSettings())
    #expect(added == 3)
    let units = Dictionary(uniqueKeysWithValues: try await h.store.allUnits().map { ($0.assetLocalIdentifier, $0) })
    #expect(units["old"]?.isBackfill == true)
    #expect(units["undated"]?.isBackfill == true)
    #expect(units["new"]?.isBackfill == false)
}
@Test func unitsCopyAssetDetails() async throws {
    let h = Harness()
    let place = Coordinate(latitude: 12.5, longitude: -3.25)
    await h.library.setAssets([photo("IMG/1", created: start, screenshot: true, location: place)])
    _ = try await h.engine.discover(settings: SyncSettings())
    let unit = try #require(try await h.store.allUnits().first)
    #expect(unit.id == "IMG/1|primary")
    #expect(unit.assetTag == AssetTag.make(localIdentifier: "IMG/1"))
    #expect(unit.status == .pending)
    #expect(unit.role == .primary)
    #expect(unit.resourceKind == .photo)
    #expect(unit.uploadFilename == "IMG/1.HEIC")
    #expect(unit.byteSize == 1234)
    #expect(unit.creationDate == start)
    #expect(unit.location == place)
    #expect(unit.isScreenshotOrRecording)
}
@Test func assetWithSeveralFilesGetsOneUnitPerFile() async throws {
    let h = Harness()
    await h.library.setAssets([
        photo(
            "raw",
            resources: [
                ResourceDescriptor(kind: .photo, originalFilename: "IMG_1.JPG"),
                ResourceDescriptor(kind: .alternatePhoto, originalFilename: "IMG_1.DNG"),
                ResourceDescriptor(kind: .pairedVideo, originalFilename: "IMG_1.MOV"),
            ])
    ])
    let added = try await h.engine.discover(settings: SyncSettings())
    #expect(added == 3)
    let ids = Set(try await h.store.allUnits().map(\.id))
    #expect(ids == ["raw|primary", "raw|raw", "raw|live"])
}
@Test func secondDiscoveryInsertsNothing() async throws {
    let h = Harness()
    await h.library.setAssets([photo("a"), photo("b")])
    #expect(try await h.engine.discover(settings: SyncSettings()) == 2)
    #expect(try await h.engine.discover(settings: SyncSettings()) == 0)
    #expect(try await h.store.allUnits().count == 2)
}
@Test func laterAssetIsInserted() async throws {
    let h = Harness()
    await h.library.setAssets([photo("a")])
    _ = try await h.engine.discover(settings: SyncSettings())
    h.clock.advance(by: 60)
    await h.library.setAssets([photo("a"), photo("b", created: h.clock.now())])
    #expect(try await h.engine.discover(settings: SyncSettings()) == 1)
    let units = try await h.store.allUnits()
    #expect(units.count == 2)
    #expect(units.first { $0.assetLocalIdentifier == "b" }?.isBackfill == false)
}
@Test func assetWithNoUsableResourcesInsertsNothing() async throws {
    let h = Harness()
    await h.library.setAssets([photo("empty", resources: [])])
    #expect(try await h.engine.discover(settings: SyncSettings()) == 0)
    #expect(try await h.store.allUnits().isEmpty)
}
@Test func disablingScreenshotsSkipsPendingScreenshots() async throws {
    let h = Harness()
    await h.library.setAssets([photo("shot", screenshot: true), photo("normal")])
    _ = try await h.engine.discover(settings: SyncSettings(includeScreenshots: false))
    let units = Dictionary(uniqueKeysWithValues: try await h.store.allUnits().map { ($0.assetLocalIdentifier, $0) })
    #expect(units["shot"]?.status == .skipped)
    #expect(units["shot"]?.skipReason == .screenshotsDisabled)
    #expect(units["normal"]?.status == .pending)
}
@Test func enablingScreenshotsRestoresThem() async throws {
    let h = Harness()
    await h.library.setAssets([photo("shot", screenshot: true)])
    _ = try await h.engine.discover(settings: SyncSettings(includeScreenshots: false))
    _ = try await h.engine.discover(settings: SyncSettings(includeScreenshots: true))
    let unit = try #require(try await h.store.allUnits().first)
    #expect(unit.status == .pending)
    #expect(unit.skipReason == nil)
}
@Test func screenshotToggleLeavesOtherStatesAlone() async throws {
    let h = Harness()
    await h.library.setAssets([photo("shot", screenshot: true), photo("big", screenshot: true)])
    _ = try await h.engine.discover(settings: SyncSettings())
    var done = try #require(try await h.store.allUnits().first { $0.assetLocalIdentifier == "shot" })
    done.status = .done
    done.messageId = 5
    try await h.store.update(done)
    var tooBig = try #require(try await h.store.allUnits().first { $0.assetLocalIdentifier == "big" })
    tooBig.status = .skipped
    tooBig.skipReason = .tooLarge
    try await h.store.update(tooBig)

    _ = try await h.engine.discover(settings: SyncSettings(includeScreenshots: false))
    _ = try await h.engine.discover(settings: SyncSettings(includeScreenshots: true))

    let units = Dictionary(uniqueKeysWithValues: try await h.store.allUnits().map { ($0.assetLocalIdentifier, $0) })
    #expect(units["shot"]?.status == .done)
    #expect(units["big"]?.status == .skipped)
    #expect(units["big"]?.skipReason == .tooLarge)
}
@Test(arguments: [LibraryAuthorization.limited, .denied, .notDetermined])
func discoveryThrowsWithoutFullAccess(level: LibraryAuthorization) async throws {
    let h = Harness(authorization: level)
    await h.library.setAssets([photo("a")])
    await #expect(throws: UploadError(kind: .permanent, message: "noLibraryAccess")) {
        _ = try await h.engine.discover(settings: SyncSettings())
    }
    #expect(try await h.store.allUnits().isEmpty)
}
