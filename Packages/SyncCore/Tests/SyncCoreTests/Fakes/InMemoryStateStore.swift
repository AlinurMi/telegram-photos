import Foundation

/// A `StateStore` that keeps everything in memory.
@testable import SyncCore

actor InMemoryStateStore: StateStore {
    private var metaValues: [MetaKey: String] = [:]
    private var units: [String: UploadUnit] = [:]
    private var places: [String: String] = [:]

    init() {}

    func meta(_ key: MetaKey) async throws -> String? { metaValues[key] }

    func setMeta(_ key: MetaKey, _ value: String?) async throws { metaValues[key] = value }

    func knownAssetIdentifiers() async throws -> Set<String> {
        Set(units.values.map(\.assetLocalIdentifier))
    }

    func insert(_ newUnits: [UploadUnit]) async throws {
        for unit in newUnits where units[unit.id] == nil { units[unit.id] = unit }
    }

    func allUnits() async throws -> [UploadUnit] { Array(units.values) }

    func update(_ unit: UploadUnit) async throws {
        guard units[unit.id] != nil else { return }
        units[unit.id] = unit
    }

    func counts() async throws -> StatusCounts {
        var counts = StatusCounts()
        for unit in units.values {
            switch unit.status {
            case .done: counts.done += 1
            case .pending:
                counts.pending += 1
                if unit.isBackfill { counts.backfillPending += 1 }
            case .uploading: counts.uploading += 1
            case .failed: counts.failed += 1
            case .skipped: counts.skipped += 1
            }
        }
        return counts
    }

    func cachedPlace(key: String) async throws -> String? { places[key] }

    func storePlace(key: String, name: String) async throws { places[key] = name }

    func resetAll() async throws {
        metaValues = [:]
        units = [:]
    }
}
