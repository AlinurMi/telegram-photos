import Testing

@testable import SyncCore

@Test func parsesPlainTagAsPrimary() {
    let parsed = ChannelIndexParser.parse(caption: "2026-01-02 10:00 · IMG_1.HEIC\n#y2026 #m01 #a0123456789")
    #expect(parsed?.assetTag == "a0123456789")
    #expect(parsed?.role == .primary)
}
@Test func parsesTagInTheMiddleOfText() {
    let parsed = ChannelIndexParser.parse(caption: "before #aabcdef0123 after")
    #expect(parsed?.assetTag == "aabcdef0123")
}
@Test func parsesTagAtStartAndEnd() {
    #expect(ChannelIndexParser.parse(caption: "#a0123456789")?.assetTag == "a0123456789")
    #expect(ChannelIndexParser.parse(caption: "x #a0123456789")?.assetTag == "a0123456789")
}
@Test func rejectsUppercaseTag() {
    #expect(ChannelIndexParser.parse(caption: "#A0123456789") == nil)
    #expect(ChannelIndexParser.parse(caption: "#a0123456ABC") == nil)
}
@Test func rejectsTooShortTag() {
    #expect(ChannelIndexParser.parse(caption: "#a012345678") == nil)
    #expect(ChannelIndexParser.parse(caption: "#a") == nil)
}
@Test func rejectsTooLongTag() {
    #expect(ChannelIndexParser.parse(caption: "#a01234567890") == nil)
    #expect(ChannelIndexParser.parse(caption: "#a0123456789_x") == nil)
}
@Test func rejectsTagThatIsNotAHashtag() {
    #expect(ChannelIndexParser.parse(caption: "a0123456789") == nil)
    #expect(ChannelIndexParser.parse(caption: "x#a0123456789") == nil)
}
@Test func rejectsNonHexCharacters() {
    #expect(ChannelIndexParser.parse(caption: "#a012345678g") == nil)
}
@Test func returnsNilWithoutATag() {
    #expect(ChannelIndexParser.parse(caption: "") == nil)
    #expect(ChannelIndexParser.parse(caption: "just a photo #y2026 #m01") == nil)
    #expect(ChannelIndexParser.parse(caption: "#live #raw") == nil)
}
@Test func takesTheFirstValidTagWhenSeveralAppear() {
    let parsed = ChannelIndexParser.parse(caption: "#a0123456789ab #a1111111111 #a2222222222")
    #expect(parsed?.assetTag == "a1111111111")
}
@Test func tagFollowedByPunctuationStillCounts() {
    #expect(ChannelIndexParser.parse(caption: "(#a0123456789), done")?.assetTag == "a0123456789")
}
@Test func rolesAreRecognised() {
    #expect(ChannelIndexParser.parse(caption: "#a0123456789 #live")?.role == .live)
    #expect(ChannelIndexParser.parse(caption: "#a0123456789 #raw")?.role == .raw)
    #expect(ChannelIndexParser.parse(caption: "#a0123456789 #edit")?.role == .edit)
}
@Test func roleTagCanComeBeforeTheAssetTag() {
    #expect(ChannelIndexParser.parse(caption: "#raw #a0123456789")?.role == .raw)
}
@Test func severalRoleTagsPickLiveThenRawThenEdit() {
    #expect(ChannelIndexParser.parse(caption: "#a0123456789 #edit #raw #live")?.role == .live)
    #expect(ChannelIndexParser.parse(caption: "#a0123456789 #edit #raw")?.role == .raw)
    #expect(ChannelIndexParser.parse(caption: "#a0123456789 #edit")?.role == .edit)
}
@Test func roleTagsMustBeWholeLowercaseWords() {
    #expect(ChannelIndexParser.parse(caption: "#a0123456789 #LIVE")?.role == .primary)
    #expect(ChannelIndexParser.parse(caption: "#a0123456789 #liveish")?.role == .primary)
    #expect(ChannelIndexParser.parse(caption: "#a0123456789 #rawr #editor")?.role == .primary)
}
@Test func parsesCaptionsBuiltByCaptionBuilder() {
    let unit = UploadUnit(
        id: "x|raw", assetLocalIdentifier: "x", assetTag: AssetTag.make(localIdentifier: "x"), role: .raw,
        resourceKind: .alternatePhoto, uploadFilename: "IMG_1.DNG")
    let caption = CaptionBuilder.build(unit: unit, placeName: "Paris", timeZone: .gmt)
    let parsed = ChannelIndexParser.parse(caption: caption.text)
    #expect(parsed?.assetTag == unit.assetTag)
    #expect(parsed?.role == .raw)
}
