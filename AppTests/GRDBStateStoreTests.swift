import SQLite3
import SyncCore
import XCTest

@testable import TelegramPhotos

final class GRDBStateStoreTests: XCTestCase {
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GRDBStateStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func unit(
        _ id: String,
        asset: String = "A",
        status: UnitStatus = .pending,
        isBackfill: Bool = false
    ) -> UploadUnit {
        UploadUnit(
            id: id,
            assetLocalIdentifier: asset,
            assetTag: AssetTag.make(localIdentifier: asset),
            role: .primary,
            resourceKind: .photo,
            uploadFilename: "\(id).HEIC",
            isBackfill: isBackfill,
            status: status
        )
    }

    /// Same checks as `stateStoreContract` in SyncCore's tests.
    func testSatisfiesTheStateStoreContract() async throws {
        let store = try GRDBStateStore(directory: directory)

        // meta
        var value = try await store.meta(.baselineDate)
        XCTAssertNil(value)
        try await store.setMeta(.baselineDate, "2026-10-27T00:00:00Z")
        value = try await store.meta(.baselineDate)
        XCTAssertEqual(value, "2026-10-27T00:00:00Z")
        try await store.setMeta(.baselineDate, nil)
        value = try await store.meta(.baselineDate)
        XCTAssertNil(value)

        // insert ignores ids that already exist, even if the new unit differs
        try await store.insert([unit("A|primary", asset: "A"), unit("B|primary", asset: "B")])
        try await store.insert([unit("A|primary", asset: "A", status: .done), unit("C|primary", asset: "C")])
        let all = try await store.allUnits()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first { $0.id == "A|primary" }?.status, .pending)
        let known = try await store.knownAssetIdentifiers()
        XCTAssertEqual(known, ["A", "B", "C"])

        // update replaces by id; unknown ids are ignored
        var changed = unit("B|primary", asset: "B", status: .done)
        changed.messageId = 42
        try await store.update(changed)
        try await store.update(unit("Z|primary", asset: "Z"))
        let afterUpdate = try await store.allUnits()
        XCTAssertEqual(afterUpdate.count, 3)
        XCTAssertEqual(afterUpdate.first { $0.id == "B|primary" }?.messageId, 42)

        // counts
        try await store.insert([
            unit("D|primary", asset: "D", status: .failed),
            unit("E|primary", asset: "E", status: .skipped),
            unit("F|primary", asset: "F", status: .uploading),
            unit("G|primary", asset: "G", isBackfill: true),
        ])
        let counts = try await store.counts()
        XCTAssertEqual(
            counts,
            StatusCounts(done: 1, pending: 3, uploading: 1, failed: 1, skipped: 1, backfillPending: 1))

        // place cache survives resetAll, units and meta don't
        var place = try await store.cachedPlace(key: "k")
        XCTAssertNil(place)
        try await store.storePlace(key: "k", name: "Bishkek")
        try await store.setMeta(.lastSuccessfulSyncAt, "x")
        try await store.resetAll()
        let remaining = try await store.allUnits()
        XCTAssertTrue(remaining.isEmpty)
        let knownAfterReset = try await store.knownAssetIdentifiers()
        XCTAssertTrue(knownAfterReset.isEmpty)
        value = try await store.meta(.lastSuccessfulSyncAt)
        XCTAssertNil(value)
        let countsAfterReset = try await store.counts()
        XCTAssertEqual(countsAfterReset, StatusCounts())
        place = try await store.cachedPlace(key: "k")
        XCTAssertEqual(place, "Bishkek")
    }

    func testEveryFieldRoundTrips() async throws {
        let store = try GRDBStateStore(directory: directory)
        let full = UploadUnit(
            id: "X|edit|1700000000",
            assetLocalIdentifier: "X",
            assetTag: "tag",
            role: .edit,
            resourceKind: .fullSizePhoto,
            uploadFilename: "IMG_0001_edited.JPG",
            byteSize: 5_000_000_000,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000.5),
            isBackfill: true,
            isScreenshotOrRecording: true,
            location: Coordinate(latitude: 42.8746, longitude: 74.5698),
            status: .skipped,
            skipReason: .tooLarge,
            attempts: 3,
            nextAttemptAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastError: "boom",
            messageId: 9_000_000_000,
            uploadedAt: Date(timeIntervalSince1970: 1_700_000_200),
            assetModifiedAt: Date(timeIntervalSince1970: 1_700_000_000.25)
        )
        try await store.insert([full, unit("Y|primary", asset: "Y")])
        let stored = try await store.allUnits()
        XCTAssertEqual(stored.first { $0.id == full.id }, full)
        XCTAssertEqual(stored.first { $0.id == "Y|primary" }, unit("Y|primary", asset: "Y"))

        var changed = full
        changed.status = .done
        changed.skipReason = nil
        changed.location = nil
        changed.lastError = nil
        changed.assetModifiedAt = nil
        try await store.update(changed)
        let updated = try await store.allUnits()
        XCTAssertEqual(updated.first { $0.id == full.id }, changed)
    }

    func testDataSurvivesReopeningTheDatabase() async throws {
        do {
            let store = try GRDBStateStore(directory: directory)
            try await store.insert([unit("A|primary")])
            try await store.setMeta(.baselineDate, "x")
            try await store.storePlace(key: "k", name: "Osh")
        }
        let reopened = try GRDBStateStore(directory: directory)
        let units = try await reopened.allUnits()
        XCTAssertEqual(units.map(\.id), ["A|primary"])
        let baseline = try await reopened.meta(.baselineDate)
        XCTAssertEqual(baseline, "x")
        let place = try await reopened.cachedPlace(key: "k")
        XCTAssertEqual(place, "Osh")
    }

    func testUpgradesAVersionOneDatabase() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let statements = [
            "CREATE TABLE unit ("
                + "id TEXT PRIMARY KEY NOT NULL, assetLocalIdentifier TEXT NOT NULL, "
                + "assetTag TEXT NOT NULL, role TEXT NOT NULL, resourceKind TEXT NOT NULL, "
                + "uploadFilename TEXT NOT NULL, byteSize INTEGER, creationDate REAL, "
                + "isBackfill INTEGER NOT NULL, isScreenshotOrRecording INTEGER NOT NULL, "
                + "latitude REAL, longitude REAL, status TEXT NOT NULL, skipReason TEXT, "
                + "attempts INTEGER NOT NULL, nextAttemptAt REAL, lastError TEXT, "
                + "messageId INTEGER, uploadedAt REAL)",
            "CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT)",
            "CREATE TABLE place (key TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL)",
            "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)",
            "INSERT INTO grdb_migrations (identifier) VALUES ('v1')",
            "INSERT INTO unit (id, assetLocalIdentifier, assetTag, role, resourceKind, uploadFilename, "
                + "isBackfill, isScreenshotOrRecording, status, attempts) "
                + "VALUES ('A|primary', 'A', 'tag', 'primary', 'photo', 'A.HEIC', 0, 0, 'done', 0)",
        ]
        var handle: OpaquePointer?
        let path = directory.appendingPathComponent("state.sqlite").path
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        for statement in statements {
            XCTAssertEqual(sqlite3_exec(handle, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        sqlite3_close(handle)

        let store = try GRDBStateStore(directory: directory)
        var units = try await store.allUnits()
        XCTAssertEqual(units.map(\.id), ["A|primary"])
        XCTAssertEqual(units.first?.status, .done)
        XCTAssertNil(units.first?.assetModifiedAt)

        var changed = try XCTUnwrap(units.first)
        changed.assetModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.update(changed)
        units = try await store.allUnits()
        XCTAssertEqual(units.first, changed)
    }

    func testStoresPlaceNameOverwrite() async throws {
        let store = try GRDBStateStore(directory: directory)
        try await store.storePlace(key: "k", name: "Old")
        try await store.storePlace(key: "k", name: "New")
        let place = try await store.cachedPlace(key: "k")
        XCTAssertEqual(place, "New")
    }
}
