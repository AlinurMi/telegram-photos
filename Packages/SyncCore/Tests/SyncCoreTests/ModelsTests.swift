import Foundation
import Testing

@testable import SyncCore

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    let data = try encoder.encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

private func makeUnit() -> UploadUnit {
    UploadUnit(
        id: "ABC/L0/001|edit|1792000000",
        assetLocalIdentifier: "ABC/L0/001",
        assetTag: "a3f9c21e8b0",
        role: .edit,
        resourceKind: .fullSizePhoto,
        uploadFilename: "IMG_1234_edited.HEIC",
        byteSize: 4_200_000,
        creationDate: Date(timeIntervalSince1970: 1_790_000_000),
        isBackfill: true,
        isScreenshotOrRecording: false,
        location: Coordinate(latitude: 42.874601, longitude: 74.612201),
        status: .failed,
        skipReason: nil,
        attempts: 3,
        nextAttemptAt: Date(timeIntervalSince1970: 1_790_000_600),
        lastError: "timeout",
        messageId: 987_654_321_012,
        uploadedAt: nil
    )
}

@Test func uploadUnitRoundTripsThroughJSON() throws {
    let unit = makeUnit()
    #expect(try roundTrip(unit) == unit)
}

@Test func uploadUnitIdentifiableUsesId() {
    #expect(makeUnit().id == "ABC/L0/001|edit|1792000000")
}

@Test func uploadUnitInitDefaults() {
    let unit = UploadUnit(
        id: "x|primary",
        assetLocalIdentifier: "x",
        assetTag: "a0000000000",
        role: .primary,
        resourceKind: .photo,
        uploadFilename: "IMG_1.JPG"
    )
    #expect(unit.status == .pending)
    #expect(unit.attempts == 0)
    #expect(unit.isBackfill == false)
    #expect(unit.location == nil)
    #expect(unit.messageId == nil)
}

@Test func rateLimitedErrorKindRoundTripsThroughJSON() throws {
    let kind = UploadErrorKind.rateLimited(retryAfterSeconds: 42)
    #expect(try roundTrip(kind) == kind)
}

@Test func everyErrorKindRoundTripsThroughJSON() throws {
    let kinds: [UploadErrorKind] = [
        .transient, .rateLimited(retryAfterSeconds: 7), .permanent, .notLocal, .tooLarge,
        .cancelled, .authLost,
    ]
    for kind in kinds { #expect(try roundTrip(kind) == kind) }
}

@Test func uploadErrorRoundTripsThroughJSON() throws {
    let error = UploadError(kind: .rateLimited(retryAfterSeconds: 30), message: "FLOOD_WAIT_30")
    #expect(try roundTrip(error) == error)
}

@Test func assetDescriptorRoundTripsThroughJSON() throws {
    let asset = AssetDescriptor(
        localIdentifier: "ABC/L0/001",
        creationDate: Date(timeIntervalSince1970: 1_790_000_000),
        modificationDate: nil,
        mediaKind: .image,
        isScreenshotOrRecording: true,
        location: Coordinate(latitude: -33.86882, longitude: 151.20929),
        resources: [
            ResourceDescriptor(kind: .photo, originalFilename: "IMG_1234.HEIC", byteSize: 100),
            ResourceDescriptor(kind: .pairedVideo, originalFilename: "IMG_1234.MOV"),
        ]
    )
    #expect(try roundTrip(asset) == asset)
    #expect(asset.resources[1].byteSize == nil)
}

@Test func syncSettingsDefaults() throws {
    let settings = SyncSettings()
    #expect(settings.includeScreenshots == true)
    #expect(settings.resendEdits == false)
    #expect(try roundTrip(settings) == settings)
}

@Test func statusCountsStartAtZero() throws {
    let counts = StatusCounts()
    #expect(counts.done == 0 && counts.pending == 0 && counts.uploading == 0)
    #expect(counts.failed == 0 && counts.skipped == 0 && counts.backfillPending == 0)
    #expect(try roundTrip(counts) == counts)
}

@Test func syncReportRoundTripsThroughJSON() throws {
    let report = SyncReport(
        trigger: .backgroundProcessing,
        startedAt: Date(timeIntervalSince1970: 1_790_000_000),
        endedAt: Date(timeIntervalSince1970: 1_790_000_100),
        uploaded: 5,
        failed: 1,
        skipped: 2,
        remainingEligible: 10,
        blockedBy: .needsCharger
    )
    #expect(try roundTrip(report) == report)
}

@Test func enumRawValuesAreStable() {
    #expect(ResourceKind.fullSizePairedVideo.rawValue == "fullSizePairedVideo")
    #expect(UnitRole.allCases == [.primary, .raw, .live, .edit])
    #expect(SyncTrigger.appLaunch.rawValue == "appLaunch")
    #expect(BlockReason.noLibraryAccess.rawValue == "noLibraryAccess")
}
