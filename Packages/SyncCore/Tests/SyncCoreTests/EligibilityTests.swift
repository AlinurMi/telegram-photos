import Foundation
import Testing

@testable import SyncCore

private let now = Date(timeIntervalSince1970: 1_000_000)
private func unit(
    _ id: String = "a|primary",
    role: UnitRole = .primary,
    creationDate: Date? = nil,
    isBackfill: Bool = false,
    isScreenshot: Bool = false,
    status: UnitStatus = .pending,
    nextAttemptAt: Date? = nil
) -> UploadUnit {
    UploadUnit(
        id: id,
        assetLocalIdentifier: "a",
        assetTag: "tag",
        role: role,
        resourceKind: .photo,
        uploadFilename: "IMG.HEIC",
        creationDate: creationDate,
        isBackfill: isBackfill,
        isScreenshotOrRecording: isScreenshot,
        status: status,
        nextAttemptAt: nextAttemptAt
    )
}

private func eligible(_ unit: UploadUnit, charging: Bool = false, settings: SyncSettings = SyncSettings()) -> Bool {
    Eligibility.isEligible(unit, now: now, charging: charging, settings: settings)
}

@Test func pendingUnitIsEligible() {
    #expect(eligible(unit()))
}

@Test(arguments: [UnitStatus.uploading, .done, .failed, .skipped])
func nonPendingStatusIsNotEligible(status: UnitStatus) {
    #expect(!eligible(unit(status: status)))
}

@Test func nextAttemptInFutureIsNotEligible() {
    #expect(!eligible(unit(nextAttemptAt: now.addingTimeInterval(1))))
}

@Test func nextAttemptExactlyNowIsEligible() {
    #expect(eligible(unit(nextAttemptAt: now)))
}

@Test func nextAttemptInPastIsEligible() {
    #expect(eligible(unit(nextAttemptAt: now.addingTimeInterval(-1))))
}

@Test func backfillNeedsCharger() {
    #expect(!eligible(unit(isBackfill: true), charging: false))
    #expect(eligible(unit(isBackfill: true), charging: true))
}

@Test func newPhotosDoNotNeedCharger() {
    #expect(eligible(unit(isBackfill: false), charging: false))
}

@Test func screenshotsFollowSetting() {
    let screenshot = unit(isScreenshot: true)
    #expect(eligible(screenshot, settings: SyncSettings(includeScreenshots: true)))
    #expect(!eligible(screenshot, settings: SyncSettings(includeScreenshots: false)))
}

@Test func regularPhotoIgnoresScreenshotSetting() {
    #expect(eligible(unit(), settings: SyncSettings(includeScreenshots: false)))
}

@Test func backfillScreenshotNeedsBothConditions() {
    let both = unit(isBackfill: true, isScreenshot: true)
    let off = SyncSettings(includeScreenshots: false)
    #expect(eligible(both, charging: true))
    #expect(!eligible(both, charging: true, settings: off))
    #expect(!eligible(both, charging: false))
}

@Test func orderedSortsByCreationDateAscending() {
    let early = unit("early|primary", creationDate: Date(timeIntervalSince1970: 100))
    let late = unit("late|primary", creationDate: Date(timeIntervalSince1970: 200))
    #expect(Eligibility.ordered([late, early]).map(\.id) == ["early|primary", "late|primary"])
}

@Test func orderedPutsNilDatesFirst() {
    let dated = unit("dated|primary", creationDate: Date(timeIntervalSince1970: 100))
    let undated = unit("undated|primary", creationDate: nil)
    #expect(Eligibility.ordered([dated, undated]).map(\.id) == ["undated|primary", "dated|primary"])
}

@Test func orderedBreaksDateTiesByRole() {
    let date = Date(timeIntervalSince1970: 100)
    let units = [
        unit("a|edit|1", role: .edit, creationDate: date),
        unit("a|live", role: .live, creationDate: date),
        unit("a|raw", role: .raw, creationDate: date),
        unit("a|primary", role: .primary, creationDate: date),
    ]
    #expect(
        Eligibility.ordered(units).map(\.role) == [.primary, .raw, .live, .edit])
}

@Test func orderedBreaksRemainingTiesById() {
    let date = Date(timeIntervalSince1970: 100)
    let units = [
        unit("b|primary", creationDate: date),
        unit("a|primary", creationDate: date),
    ]
    #expect(Eligibility.ordered(units).map(\.id) == ["a|primary", "b|primary"])
}

@Test func orderedBreaksNilDateTiesByRoleThenId() {
    let units = [
        unit("b|raw", role: .raw),
        unit("b|primary", role: .primary),
        unit("a|primary", role: .primary),
    ]
    #expect(Eligibility.ordered(units).map(\.id) == ["a|primary", "b|primary", "b|raw"])
}

@Test func orderedHandlesEmptyInput() {
    #expect(Eligibility.ordered([]).isEmpty)
}
