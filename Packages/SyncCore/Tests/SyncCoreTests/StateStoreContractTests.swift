import Foundation
import Testing

@testable import SyncCore

/// Behaviour every `StateStore` must have. Reused by the app-side database tests.

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
func stateStoreContract(_ make: () -> any StateStore) async throws {
    let store = make()

    // meta
    #expect(try await store.meta(.baselineDate) == nil)
    try await store.setMeta(.baselineDate, "2026-10-27T00:00:00Z")
    #expect(try await store.meta(.baselineDate) == "2026-10-27T00:00:00Z")
    try await store.setMeta(.baselineDate, nil)
    #expect(try await store.meta(.baselineDate) == nil)

    // insert ignores ids that already exist, even if the new unit differs
    try await store.insert([unit("A|primary", asset: "A"), unit("B|primary", asset: "B")])
    try await store.insert([unit("A|primary", asset: "A", status: .done), unit("C|primary", asset: "C")])
    let all = try await store.allUnits()
    #expect(all.count == 3)
    #expect(all.first { $0.id == "A|primary" }?.status == .pending)
    #expect(try await store.knownAssetIdentifiers() == ["A", "B", "C"])

    // update replaces by id; unknown ids are ignored
    var changed = unit("B|primary", asset: "B", status: .done)
    changed.messageId = 42
    try await store.update(changed)
    try await store.update(unit("Z|primary", asset: "Z"))
    let afterUpdate = try await store.allUnits()
    #expect(afterUpdate.count == 3)
    #expect(afterUpdate.first { $0.id == "B|primary" }?.messageId == 42)

    // counts
    try await store.insert([
        unit("D|primary", asset: "D", status: .failed),
        unit("E|primary", asset: "E", status: .skipped),
        unit("F|primary", asset: "F", status: .uploading),
        unit("G|primary", asset: "G", isBackfill: true),
    ])
    #expect(
        try await store.counts()
            == StatusCounts(done: 1, pending: 3, uploading: 1, failed: 1, skipped: 1, backfillPending: 1))

    // place cache survives resetAll, units and meta don't
    #expect(try await store.cachedPlace(key: "k") == nil)
    try await store.storePlace(key: "k", name: "Bishkek")
    try await store.setMeta(.lastSuccessfulSyncAt, "x")
    try await store.resetAll()
    #expect(try await store.allUnits().isEmpty)
    #expect(try await store.knownAssetIdentifiers().isEmpty)
    #expect(try await store.meta(.lastSuccessfulSyncAt) == nil)
    #expect(try await store.counts() == StatusCounts())
    #expect(try await store.cachedPlace(key: "k") == "Bishkek")
}
@Suite struct InMemoryStateStoreTests {
    @Test func satisfiesTheStateStoreContract() async throws {
        try await stateStoreContract { InMemoryStateStore() }
    }
}
