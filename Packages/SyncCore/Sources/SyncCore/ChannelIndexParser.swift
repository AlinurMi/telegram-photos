import Foundation

/// Reads the asset tag and role back out of a caption that `CaptionBuilder` produced.
public enum ChannelIndexParser {
    /// Returns the first `#a` + 10 lowercase hex hashtag and the role tag (`#live`, then `#raw`, then `#edit`), or `nil` if there is no asset tag.
    public static func parse(caption: String) -> (assetTag: String, role: UnitRole)? {
        let hashtags = caption.split(whereSeparator: { !isHashtagCharacter($0) }).filter { $0.first == "#" }
        guard let tag = hashtags.lazy.compactMap({ assetTag(in: $0) }).first else { return nil }
        let words = Set(hashtags)
        let role: UnitRole
        if words.contains("#live") {
            role = .live
        } else if words.contains("#raw") {
            role = .raw
        } else if words.contains("#edit") {
            role = .edit
        } else {
            role = .primary
        }
        return (tag, role)
    }

    private static func isHashtagCharacter(_ character: Character) -> Bool {
        character == "#" || character == "_" || character.isLetter || character.isNumber
    }

    private static func assetTag(in hashtag: Substring) -> String? {
        let body = hashtag.dropFirst()
        guard body.count == 11, body.first == "a" else { return nil }
        let isLowercaseHex = body.dropFirst().allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
        return isLowercaseHex ? String(body) : nil
    }
}
