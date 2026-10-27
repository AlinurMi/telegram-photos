import XCTest

@testable import TelegramPhotos

final class KeychainStoreTests: XCTestCase {
    private var store = KeychainStore(service: "io.github.alinurmi.telegramphotos.tests")
    private let key = "test.key"

    override func setUpWithError() throws {
        store = KeychainStore(service: "io.github.alinurmi.telegramphotos.tests.\(UUID().uuidString)")
        try store.set(nil, for: key)
    }

    override func tearDownWithError() throws {
        try store.set(nil, for: key)
    }

    func testMissingKeyReturnsNil() throws {
        XCTAssertNil(try store.data(for: key))
        XCTAssertNil(try store.string(for: key))
    }

    func testSetThenReadRoundTrips() throws {
        let bytes = Data([0, 1, 2, 255])
        try store.set(bytes, for: key)
        XCTAssertEqual(try store.data(for: key), bytes)
    }

    func testSetReplacesExistingValue() throws {
        try store.setString("first", for: key)
        try store.setString("second", for: key)
        XCTAssertEqual(try store.string(for: key), "second")
    }

    func testSetNilDeletes() throws {
        try store.setString("value", for: key)
        try store.set(nil, for: key)
        XCTAssertNil(try store.data(for: key))
    }

    func testDeletingMissingKeyDoesNotThrow() throws {
        XCTAssertNoThrow(try store.set(nil, for: key))
    }

    func testStringHelpersRoundTripUnicode() throws {
        try store.setString("héllo 🌍", for: key)
        XCTAssertEqual(try store.string(for: key), "héllo 🌍")
    }

    func testServicesAreIsolated() throws {
        let other = KeychainStore(service: store.service + ".other")
        try store.setString("mine", for: key)
        XCTAssertNil(try other.string(for: key))
    }
}
