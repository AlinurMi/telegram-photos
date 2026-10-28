import Foundation
import Testing

@testable import SyncCore

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let on = SyncSettings(resendEdits: true)
private let off = SyncSettings(resendEdits: false)

private struct Harness {
    let library = FakePhotoLibrary()
    let store = InMemoryStateStore()
    let engine: SyncEngine

    init() {
        engine = SyncEngine(
            library: library,
            uploader: FakeUploader(),
            store: store,
            environment: FakeEnvironment(),
            places: FakePlaceResolver(),
            clock: FixedClock(start),
            timeZone: TimeZone(identifier: "UTC") ?? .current,
            workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("edit-tests"),
            observer: nil
        )
    }

    /// Discovers `asset` and marks every unit `done`, as if it had been uploaded.
    func uploaded(_ asset: AssetDescriptor) async throws {
        await library.setAssets([asset])
        _ = try await engine.discover(settings: off)
        for var unit in try await store.allUnits() {
            unit.status = .done
            try await store.update(unit)
        }
    }

    func edits() async throws -> [UploadUnit] {
        try await store.allUnits().filter { $0.role == .edit }.sorted { $0.id < $1.id }
    }
}

private func photo(
    _ id: String = "IMG1",
    created: Date? = start.addingTimeInterval(-86_400),
    modified: Date? = start.addingTimeInterval(-86_400),
    edited: Bool = false
) -> AssetDescriptor {
    var resources = [ResourceDescriptor(kind: .photo, originalFilename: "IMG_0001.HEIC", byteSize: 100)]
    if edited {
        resources.append(ResourceDescriptor(kind: .fullSizePhoto, originalFilename: "render.JPG", byteSize: 90))
    }
    return AssetDescriptor(
        localIdentifier: id,
        creationDate: created,
        modificationDate: modified,
        mediaKind: .image,
        location: Coordinate(latitude: 1, longitude: 2),
        resources: resources
    )
}

@Test func newUnitsRememberTheAssetModificationDate() async throws {
    let h = Harness()
    await h.library.setAssets([photo(modified: start)])
    _ = try await h.engine.discover(settings: off)
    let unit = try #require(try await h.store.allUnits().first)
    #expect(unit.assetModifiedAt == start)
}

@Test func settingOffIgnoresEdits() async throws {
    let h = Harness()
    try await h.uploaded(photo())
    await h.library.setAssets([photo(modified: start, edited: true)])
    #expect(try await h.engine.discover(settings: off) == 0)
    #expect(try await h.edits().isEmpty)
}

@Test func editsMadeWhileOffAreNotSentWhenTurnedOn() async throws {
    let h = Harness()
    try await h.uploaded(photo())
    await h.library.setAssets([photo(modified: start, edited: true)])
    _ = try await h.engine.discover(settings: off)
    #expect(try await h.engine.discover(settings: on) == 0)
    #expect(try await h.edits().isEmpty)
}

@Test func newerEditAddsExactlyOneEditUnit() async throws {
    let h = Harness()
    try await h.uploaded(photo())
    await h.library.setAssets([photo(modified: start, edited: true)])
    #expect(try await h.engine.discover(settings: on) == 1)
    #expect(try await h.engine.discover(settings: on) == 0)

    let edits = try await h.edits()
    #expect(edits.count == 1)
    let edit = try #require(edits.first)
    #expect(edit.id == "IMG1|edit|\(Int(start.timeIntervalSince1970))")
    #expect(edit.role == .edit)
    #expect(edit.status == .pending)
    #expect(edit.resourceKind == .fullSizePhoto)
    #expect(edit.uploadFilename == "IMG_0001_edited.JPG")
    #expect(edit.byteSize == 90)
    #expect(edit.isBackfill == false)
    #expect(edit.assetModifiedAt == start)
    #expect(edit.assetTag == AssetTag.make(localIdentifier: "IMG1"))
    #expect(edit.creationDate == start.addingTimeInterval(-86_400))
    #expect(edit.location == Coordinate(latitude: 1, longitude: 2))
}

@Test func secondEditLaterAddsAnotherUnit() async throws {
    let h = Harness()
    try await h.uploaded(photo())
    await h.library.setAssets([photo(modified: start, edited: true)])
    _ = try await h.engine.discover(settings: on)
    await h.library.setAssets([photo(modified: start.addingTimeInterval(3_600), edited: true)])
    #expect(try await h.engine.discover(settings: on) == 1)
    #expect(try await h.edits().map(\.assetModifiedAt) == [start, start.addingTimeInterval(3_600)])
}

@Test func changeWithinAMinuteOfTheLastEditIsIgnored() async throws {
    let h = Harness()
    try await h.uploaded(photo())
    await h.library.setAssets([photo(modified: start, edited: true)])
    _ = try await h.engine.discover(settings: on)
    await h.library.setAssets([photo(modified: start.addingTimeInterval(60), edited: true)])
    #expect(try await h.engine.discover(settings: on) == 0)
    #expect(try await h.edits().count == 1)
}

@Test func unchangedAssetAddsNothing() async throws {
    let h = Harness()
    try await h.uploaded(photo())
    #expect(try await h.engine.discover(settings: on) == 0)
    await h.library.setAssets([photo(modified: start.addingTimeInterval(-86_400 + 60))])
    #expect(try await h.engine.discover(settings: on) == 0)
    #expect(try await h.edits().isEmpty)
}

@Test func assetNotYetUploadedGetsNoEditUnit() async throws {
    let h = Harness()
    await h.library.setAssets([photo()])
    _ = try await h.engine.discover(settings: on)
    await h.library.setAssets([photo(modified: start, edited: true)])
    #expect(try await h.engine.discover(settings: on) == 0)
    #expect(try await h.edits().isEmpty)
}

@Test func unitWithoutStoredDateAdoptsTheCurrentOneInsteadOfSending() async throws {
    let h = Harness()
    try await h.uploaded(photo())
    var primary = try #require(try await h.store.allUnits().first)
    primary.assetModifiedAt = nil
    try await h.store.update(primary)

    await h.library.setAssets([photo(modified: start, edited: true)])
    #expect(try await h.engine.discover(settings: on) == 0)
    #expect(try await h.store.allUnits().first?.assetModifiedAt == start)

    await h.library.setAssets([photo(modified: start.addingTimeInterval(3_600), edited: true)])
    #expect(try await h.engine.discover(settings: on) == 1)
}

@Test func revertedEditSendsTheOriginal() async throws {
    let h = Harness()
    try await h.uploaded(photo(edited: true))
    await h.library.setAssets([photo(modified: start, edited: false)])
    _ = try await h.engine.discover(settings: on)
    let edit = try #require(try await h.edits().first)
    #expect(edit.resourceKind == .photo)
    #expect(edit.uploadFilename == "IMG_0001.HEIC")
}

@Test func editedVideoSendsTheFullSizeRender() async throws {
    let h = Harness()
    let video = { (modified: Date, edited: Bool) -> AssetDescriptor in
        var resources = [ResourceDescriptor(kind: .video, originalFilename: "IMG_0002.MOV")]
        if edited { resources.append(ResourceDescriptor(kind: .fullSizeVideo, originalFilename: "render.mov")) }
        return AssetDescriptor(
            localIdentifier: "V", creationDate: start, modificationDate: modified, mediaKind: .video,
            resources: resources)
    }
    try await h.uploaded(video(start, false))
    await h.library.setAssets([video(start.addingTimeInterval(3_600), true)])
    _ = try await h.engine.discover(settings: on)
    let edit = try #require(try await h.edits().first)
    #expect(edit.resourceKind == .fullSizeVideo)
    #expect(edit.uploadFilename == "IMG_0002_edited.MOV")
}

@Test func assetWithoutModificationDateGetsNoEditUnit() async throws {
    let h = Harness()
    try await h.uploaded(photo(modified: nil))
    await h.library.setAssets([photo(modified: nil, edited: true)])
    #expect(try await h.engine.discover(settings: on) == 0)
}
