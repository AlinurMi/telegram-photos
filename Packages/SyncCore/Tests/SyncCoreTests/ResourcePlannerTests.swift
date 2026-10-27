import Foundation
import Testing

@testable import SyncCore

private func resource(_ kind: ResourceKind, _ name: String, _ size: Int64? = nil) -> ResourceDescriptor {
    ResourceDescriptor(kind: kind, originalFilename: name, byteSize: size)
}
private func image(_ resources: [ResourceDescriptor]) -> AssetDescriptor {
    AssetDescriptor(localIdentifier: "id", mediaKind: .image, resources: resources)
}
private func video(_ resources: [ResourceDescriptor]) -> AssetDescriptor {
    AssetDescriptor(localIdentifier: "id", mediaKind: .video, resources: resources)
}
@Test func unmodifiedPhotoUsesOriginalName() {
    let plan = ResourcePlanner.plan(image([resource(.photo, "IMG_0001.HEIC", 100)]))
    #expect(
        plan == [
            PlannedUnit(role: .primary, resourceKind: .photo, uploadFilename: "IMG_0001.HEIC", byteSize: 100)
        ])
}
@Test func editedPhotoUsesFullSizeRender() {
    let plan = ResourcePlanner.plan(
        image([resource(.photo, "IMG_0001.HEIC", 100), resource(.fullSizePhoto, "FullSizeRender.jpeg", 80)]))
    #expect(
        plan == [
            PlannedUnit(
                role: .primary, resourceKind: .fullSizePhoto, uploadFilename: "IMG_0001_edited.JPEG", byteSize: 80)
        ])
}
@Test func rawPlusJpegProducesPrimaryThenRaw() {
    let plan = ResourcePlanner.plan(
        image([resource(.photo, "IMG_0002.JPG", 10), resource(.alternatePhoto, "IMG_0002.DNG", 50)]))
    #expect(
        plan == [
            PlannedUnit(role: .primary, resourceKind: .photo, uploadFilename: "IMG_0002.JPG", byteSize: 10),
            PlannedUnit(role: .raw, resourceKind: .alternatePhoto, uploadFilename: "IMG_0002.DNG", byteSize: 50),
        ])
}
@Test func rawKeepsItsOwnFilename() {
    let plan = ResourcePlanner.plan(
        image([resource(.photo, "IMG_0002.JPG"), resource(.alternatePhoto, "RAW_0002.ARW")]))
    #expect(plan.last?.uploadFilename == "RAW_0002.ARW")
}
@Test func unmodifiedLivePhotoUsesPairedVideo() {
    let plan = ResourcePlanner.plan(
        image([resource(.photo, "IMG_0003.HEIC", 10), resource(.pairedVideo, "IMG_0003.mov", 30)]))
    #expect(
        plan == [
            PlannedUnit(role: .primary, resourceKind: .photo, uploadFilename: "IMG_0003.HEIC", byteSize: 10),
            PlannedUnit(role: .live, resourceKind: .pairedVideo, uploadFilename: "IMG_0003.MOV", byteSize: 30),
        ])
}
@Test func editedStillWithOriginalLiveVideo() {
    let plan = ResourcePlanner.plan(
        image([
            resource(.photo, "IMG_0003.HEIC"), resource(.fullSizePhoto, "FullSizeRender.heic"),
            resource(.pairedVideo, "IMG_0003.mov"),
        ]))
    #expect(plan.map(\.uploadFilename) == ["IMG_0003_edited.HEIC", "IMG_0003.MOV"])
    #expect(plan.map(\.role) == [.primary, .live])
}
@Test func editedLivePhotoPrefersEditedPairedVideo() {
    let plan = ResourcePlanner.plan(
        image([
            resource(.photo, "IMG_0004.HEIC", 10),
            resource(.fullSizePhoto, "FullSizeRender.jpeg", 11),
            resource(.pairedVideo, "IMG_0004.mov", 30),
            resource(.fullSizePairedVideo, "FullSizeRender.mov", 31),
        ]))
    #expect(
        plan == [
            PlannedUnit(
                role: .primary, resourceKind: .fullSizePhoto, uploadFilename: "IMG_0004_edited.JPEG", byteSize: 11),
            PlannedUnit(
                role: .live, resourceKind: .fullSizePairedVideo, uploadFilename: "IMG_0004_edited.MOV", byteSize: 31),
        ])
}
@Test func editedPairedVideoUsesItsActualExtension() {
    let plan = ResourcePlanner.plan(
        image([resource(.photo, "IMG_0004.HEIC"), resource(.fullSizePairedVideo, "FullSizeRender.mp4")]))
    #expect(plan.last?.uploadFilename == "IMG_0004_edited.MP4")
}
@Test func rawAndLiveOrderIsPrimaryRawLive() {
    let plan = ResourcePlanner.plan(
        image([
            resource(.pairedVideo, "IMG_0005.mov"), resource(.alternatePhoto, "IMG_0005.DNG"),
            resource(.photo, "IMG_0005.JPG"),
        ]))
    #expect(plan.map(\.role) == [.primary, .raw, .live])
}
@Test func plainVideoUsesOriginalName() {
    let plan = ResourcePlanner.plan(video([resource(.video, "IMG_0006.MOV", 900)]))
    #expect(
        plan == [PlannedUnit(role: .primary, resourceKind: .video, uploadFilename: "IMG_0006.MOV", byteSize: 900)])
}
@Test func editedVideoUsesFullSizeRender() {
    let plan = ResourcePlanner.plan(
        video([resource(.video, "IMG_0006.MOV", 900), resource(.fullSizeVideo, "FullSizeRender.mp4", 700)]))
    #expect(
        plan == [
            PlannedUnit(
                role: .primary, resourceKind: .fullSizeVideo, uploadFilename: "IMG_0006_edited.MP4", byteSize: 700)
        ])
}
@Test func videoNeverProducesRawOrLiveUnits() {
    let plan = ResourcePlanner.plan(
        video([resource(.video, "IMG_0007.MOV"), resource(.alternatePhoto, "x.DNG"), resource(.pairedVideo, "x.mov")]))
    #expect(plan.map(\.role) == [.primary])
}
@Test func filenameWithoutExtensionStaysWhole() {
    let plan = ResourcePlanner.plan(image([resource(.photo, "IMG_0008")]))
    #expect(plan.map(\.uploadFilename) == ["IMG_0008"])
}
@Test func editedFilenameWithoutExtensionDropsTheDot() {
    let plan = ResourcePlanner.plan(
        image([resource(.photo, "IMG_0008"), resource(.fullSizePhoto, "FullSizeRender")]))
    #expect(plan.map(\.uploadFilename) == ["IMG_0008_edited"])
}
@Test func baseKeepsInnerDots() {
    let plan = ResourcePlanner.plan(
        image([resource(.photo, "my.holiday.pic.heic"), resource(.fullSizePhoto, "FullSizeRender.jpeg")]))
    #expect(plan.map(\.uploadFilename) == ["my.holiday.pic_edited.JPEG"])
}
@Test func lowercaseExtensionsBecomeUppercaseOnEditedFiles() {
    let plan = ResourcePlanner.plan(
        image([resource(.photo, "a.heic"), resource(.fullSizePhoto, "b.jpg"), resource(.pairedVideo, "a.mov")]))
    #expect(plan.map(\.uploadFilename) == ["a_edited.JPG", "a.MOV"])
}
@Test func originalNameFallsBackToFirstResourceWhenPhotoIsMissing() {
    let plan = ResourcePlanner.plan(image([resource(.fullSizePhoto, "Render.jpeg")]))
    #expect(plan.map(\.uploadFilename) == ["Render_edited.JPEG"])
}
@Test func originalNameFallsBackToAssetWhenFilenameIsEmpty() {
    let plan = ResourcePlanner.plan(image([resource(.fullSizePhoto, "")]))
    #expect(plan.map(\.uploadFilename) == ["asset_edited"])
}
@Test func assetWithoutResourcesPlansNothing() {
    #expect(ResourcePlanner.plan(image([])).isEmpty)
    #expect(ResourcePlanner.plan(video([])).isEmpty)
}
@Test func imageWithOnlyAVideoResourcePlansNothing() {
    #expect(ResourcePlanner.plan(image([resource(.pairedVideo, "x.mov")])).isEmpty)
}
@Test func byteSizeIsCarriedThroughAndMayBeUnknown() {
    let plan = ResourcePlanner.plan(image([resource(.photo, "a.jpg", nil)]))
    #expect(plan.first?.byteSize == nil)
}
