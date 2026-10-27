/// A clickable range in a caption, measured in UTF-16 code units as Telegram expects.
import Foundation

/// The caption text of an upload plus the links inside it.

/// Builds the caption sent with each uploaded document.
public struct TextLink: Sendable, Equatable {
    public var utf16Offset: Int
    public var utf16Length: Int
    public var url: String

    /// Creates a link covering `utf16Length` UTF-16 units starting at `utf16Offset`.
    public init(utf16Offset: Int, utf16Length: Int, url: String) {
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
        self.url = url
    }
}
public struct Caption: Sendable, Equatable {
    public var text: String
    public var links: [TextLink]

    /// Creates a caption from its text and links.
    public init(text: String, links: [TextLink] = []) {
        self.text = text
        self.links = links
    }
}
public enum CaptionBuilder {
    /// Builds the three-line caption (date and filename, location, hashtags), keeping it within `maxLength` characters.
    public static func build(
        unit: UploadUnit, placeName: String?, timeZone: TimeZone, maxLength: Int = 1024
    ) -> Caption {
        let datePart = unit.creationDate.map { dateParts(of: $0, in: timeZone) }
        let coordinates = unit.location.map { CoordinateText($0) }
        let place = placeName.flatMap { $0.isEmpty ? nil : $0 }

        func render(place: String?, filename: String) -> Caption {
            var text = datePart.map { "\($0.stamp) · \(filename)" } ?? filename
            var links: [TextLink] = []
            if let coordinates {
                text += "\n📍 "
                if let place { text += "\(place) · " }
                links.append(
                    TextLink(
                        utf16Offset: text.utf16.count,
                        utf16Length: coordinates.display.utf16.count,
                        url: coordinates.mapURL))
                text += coordinates.display
            }
            text += "\n" + hashtagLine(unit: unit, datePart: datePart)
            return Caption(text: text, links: links)
        }

        var currentPlace = place
        var filename = unit.uploadFilename
        var caption = render(place: currentPlace, filename: filename)

        if caption.text.count > maxLength, let fullPlace = place {
            currentPlace = nil
            var keep = fullPlace.count - (caption.text.count - maxLength) - 1
            while keep >= 1 {
                let candidate = String(fullPlace.prefix(keep)) + "…"
                if render(place: candidate, filename: filename).text.count <= maxLength {
                    currentPlace = candidate
                    break
                }
                keep -= 1
            }
            caption = render(place: currentPlace, filename: filename)
        }

        if caption.text.count > maxLength {
            let (base, ext) = splitExtension(unit.uploadFilename)
            var keep = base.count - (caption.text.count - maxLength) - 1
            while true {
                keep = max(keep, 0)
                filename = String(base.prefix(keep)) + "…" + ext
                caption = render(place: currentPlace, filename: filename)
                if caption.text.count <= maxLength || keep == 0 { break }
                keep -= 1
            }
        }
        return caption
    }

    private struct DateParts {
        var stamp: String
        var year: String
        var month: String
    }

    private static func dateParts(of date: Date, in timeZone: TimeZone) -> DateParts {
        func format(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        return DateParts(
            stamp: format("yyyy-MM-dd HH:mm"), year: format("yyyy"), month: format("MM"))
    }

    private static func hashtagLine(unit: UploadUnit, datePart: DateParts?) -> String {
        var tags: [String] = []
        if let datePart {
            tags.append("#y\(datePart.year)")
            tags.append("#m\(datePart.month)")
        }
        tags.append("#\(unit.assetTag)")
        switch unit.role {
        case .primary: break
        case .live: tags.append("#live")
        case .raw: tags.append("#raw")
        case .edit: tags.append("#edit")
        }
        return tags.joined(separator: " ")
    }

    /// Splits `"IMG_1.HEIC"` into `("IMG_1", ".HEIC")`; names without a usable extension keep an empty one.
    private static func splitExtension(_ filename: String) -> (base: String, ext: String) {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else {
            return (filename, "")
        }
        return (String(filename[..<dot]), String(filename[dot...]))
    }

    private struct CoordinateText {
        var display: String
        var mapURL: String

        init(_ coordinate: Coordinate) {
            let latitude = Self.fixed(coordinate.latitude)
            let longitude = Self.fixed(coordinate.longitude)
            display = "\(latitude), \(longitude)"
            mapURL = "https://maps.apple.com/?ll=\(latitude),\(longitude)"
        }

        /// Five decimals with a `.` separator, never `-0.00000`.
        private static func fixed(_ value: Double) -> String {
            let text = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
            return text == "-0.00000" ? "0.00000" : text
        }
    }
}
