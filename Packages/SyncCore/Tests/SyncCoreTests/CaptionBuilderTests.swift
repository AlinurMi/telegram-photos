import Foundation
import Testing

@testable import SyncCore

private let utc = TimeZone(identifier: "UTC")!

/// 2026-10-27 14:32:00 UTC.
private let goldenDate = Date(timeIntervalSince1970: 1_793_111_520)
private func makeUnit(
    role: UnitRole = .primary,
    filename: String = "IMG_1234.HEIC",
    tag: String = "a3f9c21e8b0",
    date: Date? = goldenDate,
    location: Coordinate? = Coordinate(latitude: 42.874601, longitude: 74.612201)
) -> UploadUnit {
    UploadUnit(
        id: "X|\(role.rawValue)",
        assetLocalIdentifier: "X",
        assetTag: tag,
        role: role,
        resourceKind: .photo,
        uploadFilename: filename,
        creationDate: date,
        location: location
    )
}

private func substring(_ text: String, _ link: TextLink) -> String {
    NSString(string: text).substring(
        with: NSRange(location: link.utf16Offset, length: link.utf16Length))
}

@Test func goldenCaptionWithPlace() throws {
    let caption = CaptionBuilder.build(
        unit: makeUnit(), placeName: "Bishkek, Kyrgyzstan", timeZone: utc)
    #expect(
        caption.text
            == "2026-10-27 14:32 · IMG_1234.HEIC\n📍 Bishkek, Kyrgyzstan · 42.87460, 74.61220\n#y2026 #m10 #a3f9c21e8b0"
    )
    let link = try #require(caption.links.first)
    #expect(caption.links.count == 1)
    #expect(substring(caption.text, link) == "42.87460, 74.61220")
    #expect(link.url == "https://maps.apple.com/?ll=42.87460,74.61220")
}

@Test func captionWithoutPlaceLinksRightAfterPin() throws {
    let caption = CaptionBuilder.build(unit: makeUnit(), placeName: nil, timeZone: utc)
    let lines = caption.text.components(separatedBy: "\n")
    #expect(lines[1] == "📍 42.87460, 74.61220")
    let link = try #require(caption.links.first)
    #expect(substring(caption.text, link) == "42.87460, 74.61220")
    let prefix = "2026-10-27 14:32 · IMG_1234.HEIC\n📍 "
    #expect(link.utf16Offset == prefix.utf16.count)
}

@Test func emptyPlaceNameIsTreatedAsNoPlace() {
    let caption = CaptionBuilder.build(unit: makeUnit(), placeName: "", timeZone: utc)
    #expect(caption.text.components(separatedBy: "\n")[1] == "📍 42.87460, 74.61220")
}

@Test func captionWithoutLocationHasTwoLinesAndNoLinks() {
    let caption = CaptionBuilder.build(unit: makeUnit(location: nil), placeName: "Ignored", timeZone: utc)
    #expect(
        caption.text == "2026-10-27 14:32 · IMG_1234.HEIC\n#y2026 #m10 #a3f9c21e8b0")
    #expect(caption.links.isEmpty)
}

@Test func captionWithoutDateOmitsDateAndDateTags() {
    let caption = CaptionBuilder.build(
        unit: makeUnit(date: nil, location: nil), placeName: nil, timeZone: utc)
    #expect(caption.text == "IMG_1234.HEIC\n#a3f9c21e8b0")
}

@Test func captionWithoutDateKeepsLocationLine() throws {
    let caption = CaptionBuilder.build(unit: makeUnit(date: nil), placeName: "Osh", timeZone: utc)
    #expect(caption.text == "IMG_1234.HEIC\n📍 Osh · 42.87460, 74.61220\n#a3f9c21e8b0")
    let link = try #require(caption.links.first)
    #expect(substring(caption.text, link) == "42.87460, 74.61220")
}

@Test func liveRoleAddsLiveTag() {
    let caption = CaptionBuilder.build(
        unit: makeUnit(role: .live, filename: "IMG_1234.MOV", location: nil), placeName: nil,
        timeZone: utc)
    #expect(caption.text.hasSuffix("#y2026 #m10 #a3f9c21e8b0 #live"))
}

@Test func rawRoleAddsRawTag() {
    let caption = CaptionBuilder.build(
        unit: makeUnit(role: .raw, filename: "IMG_1234.DNG", location: nil), placeName: nil,
        timeZone: utc)
    #expect(caption.text.hasSuffix("#y2026 #m10 #a3f9c21e8b0 #raw"))
}

@Test func editRoleAddsEditTag() {
    let caption = CaptionBuilder.build(
        unit: makeUnit(role: .edit, filename: "IMG_1234_edited.JPG", location: nil),
        placeName: nil, timeZone: utc)
    #expect(caption.text.hasSuffix("#y2026 #m10 #a3f9c21e8b0 #edit"))
}

@Test func primaryRoleAddsNoRoleTag() {
    let caption = CaptionBuilder.build(unit: makeUnit(location: nil), placeName: nil, timeZone: utc)
    #expect(caption.text.hasSuffix("#a3f9c21e8b0"))
}

@Test func timeZoneShiftsTheHour() throws {
    let bishkek = try #require(TimeZone(identifier: "Asia/Bishkek"))
    let caption = CaptionBuilder.build(
        unit: makeUnit(location: nil), placeName: nil, timeZone: bishkek)
    #expect(caption.text.hasPrefix("2026-10-27 20:32 · "))
}

@Test func timeZoneCanShiftTheDayAndMonthTags() throws {
    // 2026-10-31 20:00 UTC is already 1 November in Auckland.
    let date = Date(timeIntervalSince1970: goldenDate.timeIntervalSince1970 + 4 * 86_400 + 5 * 3_600 + 28 * 60)
    let auckland = try #require(TimeZone(identifier: "Pacific/Auckland"))
    let caption = CaptionBuilder.build(
        unit: makeUnit(date: date, location: nil), placeName: nil, timeZone: auckland)
    #expect(caption.text.hasPrefix("2026-11-01 "))
    #expect(caption.text.contains("#y2026 #m11"))
}

@Test func negativeCoordinatesKeepTheirSign() throws {
    let unit = makeUnit(location: Coordinate(latitude: -33.86882, longitude: 151.20929))
    let caption = CaptionBuilder.build(unit: unit, placeName: "Sydney, Australia", timeZone: utc)
    let link = try #require(caption.links.first)
    #expect(substring(caption.text, link) == "-33.86882, 151.20929")
    #expect(link.url == "https://maps.apple.com/?ll=-33.86882,151.20929")
}

@Test func coordinatesUseFiveDecimalsAndDotSeparator() throws {
    let unit = makeUnit(location: Coordinate(latitude: 1, longitude: 1234.5))
    let caption = CaptionBuilder.build(unit: unit, placeName: nil, timeZone: utc)
    let link = try #require(caption.links.first)
    #expect(substring(caption.text, link) == "1.00000, 1234.50000")
}

@Test func tinyNegativeCoordinateDoesNotPrintNegativeZero() throws {
    let unit = makeUnit(location: Coordinate(latitude: -0.000001, longitude: 0.000001))
    let caption = CaptionBuilder.build(unit: unit, placeName: nil, timeZone: utc)
    let link = try #require(caption.links.first)
    #expect(substring(caption.text, link) == "0.00000, 0.00000")
}

@Test func linkOffsetsAreUTF16WithEmojiInPlaceName() throws {
    let caption = CaptionBuilder.build(
        unit: makeUnit(), placeName: "🏔️ Ala-Too 🇰🇬", timeZone: utc)
    let link = try #require(caption.links.first)
    #expect(substring(caption.text, link) == "42.87460, 74.61220")
    #expect(link.utf16Length == "42.87460, 74.61220".utf16.count)
}

@Test func linkOffsetIsUTF16NotCharacterCount() throws {
    let caption = CaptionBuilder.build(
        unit: makeUnit(filename: "📷.HEIC"), placeName: nil, timeZone: utc)
    let link = try #require(caption.links.first)
    let characterOffset = caption.text.distance(
        from: caption.text.startIndex,
        to: try #require(caption.text.range(of: "42.87460")).lowerBound)
    #expect(link.utf16Offset > characterOffset)
    #expect(substring(caption.text, link) == "42.87460, 74.61220")
}

@Test func longPlaceNameIsTruncatedFirst() throws {
    let place = String(repeating: "Verylongplace ", count: 120)
    let caption = CaptionBuilder.build(unit: makeUnit(), placeName: place, timeZone: utc)
    #expect(caption.text.count <= 1024)
    #expect(caption.text.hasPrefix("2026-10-27 14:32 · IMG_1234.HEIC\n📍 Verylongplace"))
    #expect(caption.text.contains("… · 42.87460, 74.61220"))
    let link = try #require(caption.links.first)
    #expect(substring(caption.text, link) == "42.87460, 74.61220")
    #expect(caption.text.hasSuffix("#y2026 #m10 #a3f9c21e8b0"))
}

@Test func truncationRespectsCustomMaxLength() throws {
    let caption = CaptionBuilder.build(
        unit: makeUnit(), placeName: "Bishkek, Kyrgyzstan", timeZone: utc, maxLength: 90)
    #expect(caption.text.count <= 90)
    #expect(caption.text.contains("…"))
    let link = try #require(caption.links.first)
    #expect(substring(caption.text, link) == "42.87460, 74.61220")
}

@Test func placeIsDroppedWhenShorteningItIsNotEnough() throws {
    let unit = makeUnit()
    let full = CaptionBuilder.build(unit: unit, placeName: nil, timeZone: utc)
    let caption = CaptionBuilder.build(
        unit: unit, placeName: "Bishkek, Kyrgyzstan", timeZone: utc, maxLength: full.text.count)
    #expect(caption == full)
    #expect(!caption.text.contains("Bishkek"))
}

@Test func filenameBaseIsShortenedLastAndKeepsExtension() throws {
    let filename = String(repeating: "N", count: 300) + ".HEIC"
    let unit = makeUnit(filename: filename)
    let caption = CaptionBuilder.build(
        unit: unit, placeName: "Bishkek, Kyrgyzstan", timeZone: utc, maxLength: 120)
    #expect(caption.text.count <= 120)
    let firstLine = caption.text.components(separatedBy: "\n")[0]
    #expect(firstLine.hasSuffix("….HEIC"))
    #expect(!caption.text.contains("Bishkek"))
    let link = try #require(caption.links.first)
    #expect(substring(caption.text, link) == "42.87460, 74.61220")
}

@Test func captionThatFitsIsNotTruncated() {
    let caption = CaptionBuilder.build(
        unit: makeUnit(), placeName: "Bishkek, Kyrgyzstan", timeZone: utc, maxLength: 1024)
    #expect(!caption.text.contains("…"))
}
