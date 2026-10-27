import Foundation

import Testing

@testable import SyncCore

@Test func fnv1aOfEmptyInputIsOffsetBasis() {
    #expect(AssetTag.fnv1a64([]) == 0xcbf2_9ce4_8422_2325)
}
@Test func fnv1aOfSingleByteMatchesReferenceValue() {
    #expect(AssetTag.fnv1a64(Array("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
}
@Test func makeProducesExpectedTagForKnownInput() {
    #expect(AssetTag.make(localIdentifier: "a") == "aaf63dc4c86")
}
@Test func makeAlwaysMatchesTagShape() {
    let inputs = [
        "", "a", "ABC123/L0/001", "📷 emoji ✨", String(repeating: "x", count: 500),
        "9F1B3C2E-6D5A-4C7B-8E21-0A1B2C3D4E5F/L0/001",
    ]
    for input in inputs {
        let tag = AssetTag.make(localIdentifier: input)
        #expect(tag.count == 11)
        #expect(tag.range(of: "^a[0-9a-f]{10}$", options: .regularExpression) != nil)
    }
}
@Test func makeOfEmptyInputUsesOffsetBasis() {
    #expect(AssetTag.make(localIdentifier: "") == "acbf29ce484")
}
@Test func makeIsDeterministic() {
    let id = "9F1B3C2E-6D5A-4C7B-8E21-0A1B2C3D4E5F/L0/001"
    #expect(AssetTag.make(localIdentifier: id) == AssetTag.make(localIdentifier: id))
}
@Test func makeDiffersForDifferentInputs() {
    #expect(AssetTag.make(localIdentifier: "a") != AssetTag.make(localIdentifier: "b"))
}
