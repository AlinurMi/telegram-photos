import Foundation
import GRDB
import SyncCore

/// The app's `StateStore`, backed by a SQLite file through GRDB.
///
/// Dates are stored as Unix seconds, enums as their raw strings and the location as two nullable columns.
/// Never log row contents: they hold coordinates and file names.
final class GRDBStateStore: StateStore {
    private let pool: DatabasePool

    /// Opens (or creates) `state.sqlite` inside `directory` and brings the schema up to date.
    init(directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        let pool = try DatabasePool(path: directory.appendingPathComponent("state.sqlite").path)
        try Self.migrator.migrate(pool)
        self.pool = pool
    }

    /// `Application Support/` of the app.
    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private static let unitColumns = [
        "id", "assetLocalIdentifier", "assetTag", "role", "resourceKind", "uploadFilename",
        "byteSize", "creationDate", "isBackfill", "isScreenshotOrRecording", "latitude", "longitude",
        "status", "skipReason", "attempts", "nextAttemptAt", "lastError", "messageId", "uploadedAt",
    ]

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: "CREATE TABLE unit ("
                    + "id TEXT PRIMARY KEY NOT NULL, assetLocalIdentifier TEXT NOT NULL, "
                    + "assetTag TEXT NOT NULL, role TEXT NOT NULL, resourceKind TEXT NOT NULL, "
                    + "uploadFilename TEXT NOT NULL, byteSize INTEGER, creationDate REAL, "
                    + "isBackfill INTEGER NOT NULL, isScreenshotOrRecording INTEGER NOT NULL, "
                    + "latitude REAL, longitude REAL, status TEXT NOT NULL, skipReason TEXT, "
                    + "attempts INTEGER NOT NULL, nextAttemptAt REAL, lastError TEXT, "
                    + "messageId INTEGER, uploadedAt REAL)")
            try db.execute(sql: "CREATE INDEX unit_status ON unit(status)")
            try db.execute(sql: "CREATE INDEX unit_assetLocalIdentifier ON unit(assetLocalIdentifier)")
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT)")
            try db.execute(sql: "CREATE TABLE place (key TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL)")
        }
        return migrator
    }

    func meta(_ key: MetaKey) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key.rawValue])
        }
    }

    func setMeta(_ key: MetaKey, _ value: String?) async throws {
        try await pool.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                    arguments: [key.rawValue, value])
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key.rawValue])
            }
        }
    }

    func knownAssetIdentifiers() async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT assetLocalIdentifier FROM unit"))
        }
    }

    func insert(_ units: [UploadUnit]) async throws {
        let columns = Self.unitColumns.joined(separator: ", ")
        let marks = Self.unitColumns.map { _ in "?" }.joined(separator: ", ")
        let sql = "INSERT OR IGNORE INTO unit (\(columns)) VALUES (\(marks))"
        try await pool.write { db in
            for unit in units {
                try db.execute(sql: sql, arguments: StatementArguments(unit.columnValues))
            }
        }
    }

    func allUnits() async throws -> [UploadUnit] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM unit").map(UploadUnit.init(row:))
        }
    }

    func update(_ unit: UploadUnit) async throws {
        let assignments = Self.unitColumns.dropFirst().map { "\($0) = ?" }.joined(separator: ", ")
        let sql = "UPDATE unit SET \(assignments) WHERE id = ?"
        try await pool.write { db in
            var values = Array(unit.columnValues.dropFirst())
            values.append(unit.id)
            try db.execute(sql: sql, arguments: StatementArguments(values))
        }
    }

    func counts() async throws -> StatusCounts {
        try await pool.read { db in
            var counts = StatusCounts()
            let rows = try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS n FROM unit GROUP BY status")
            for row in rows {
                let status: String = row["status"]
                let count: Int = row["n"]
                switch UnitStatus(rawValue: status) {
                case .done: counts.done = count
                case .pending: counts.pending = count
                case .uploading: counts.uploading = count
                case .failed: counts.failed = count
                case .skipped: counts.skipped = count
                case nil: break
                }
            }
            let backfill = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM unit WHERE status = ? AND isBackfill = 1",
                arguments: [UnitStatus.pending.rawValue])
            counts.backfillPending = backfill ?? 0
            return counts
        }
    }

    func cachedPlace(key: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM place WHERE key = ?", arguments: [key])
        }
    }

    func storePlace(key: String, name: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO place (key, name) VALUES (?, ?)", arguments: [key, name])
        }
    }

    func resetAll() async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM unit")
            try db.execute(sql: "DELETE FROM meta")
        }
    }
}

/// Problems reading the state database.
enum StateStoreError: Error {
    /// A stored row has a value this version doesn't understand.
    case unreadableRow
}

extension UploadUnit {
    /// Values in the order of `GRDBStateStore.unitColumns`.
    fileprivate var columnValues: [(any DatabaseValueConvertible)?] {
        [
            id, assetLocalIdentifier, assetTag, role.rawValue, resourceKind.rawValue, uploadFilename,
            byteSize, creationDate?.timeIntervalSince1970, isBackfill, isScreenshotOrRecording,
            location?.latitude, location?.longitude,
            status.rawValue, skipReason?.rawValue, attempts, nextAttemptAt?.timeIntervalSince1970,
            lastError, messageId, uploadedAt?.timeIntervalSince1970,
        ]
    }

    fileprivate init(row: Row) throws {
        guard
            let role = UnitRole(rawValue: row["role"]),
            let resourceKind = ResourceKind(rawValue: row["resourceKind"]),
            let status = UnitStatus(rawValue: row["status"])
        else {
            throw StateStoreError.unreadableRow
        }
        var location: Coordinate?
        if let latitude = row["latitude"] as Double?, let longitude = row["longitude"] as Double? {
            location = Coordinate(latitude: latitude, longitude: longitude)
        }
        let skipReason = (row["skipReason"] as String?).flatMap(SkipReason.init(rawValue:))
        self.init(
            id: row["id"],
            assetLocalIdentifier: row["assetLocalIdentifier"],
            assetTag: row["assetTag"],
            role: role,
            resourceKind: resourceKind,
            uploadFilename: row["uploadFilename"],
            byteSize: row["byteSize"],
            creationDate: (row["creationDate"] as Double?).map(Date.init(timeIntervalSince1970:)),
            isBackfill: row["isBackfill"],
            isScreenshotOrRecording: row["isScreenshotOrRecording"],
            location: location,
            status: status,
            skipReason: skipReason,
            attempts: row["attempts"],
            nextAttemptAt: (row["nextAttemptAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
            lastError: row["lastError"],
            messageId: row["messageId"],
            uploadedAt: (row["uploadedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }
}
