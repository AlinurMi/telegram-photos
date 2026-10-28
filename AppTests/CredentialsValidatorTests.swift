import XCTest

@testable import TelegramPhotos

final class CredentialsValidatorTests: XCTestCase {
    func testApiIdAcceptsDigitsOnly() {
        XCTAssertEqual(CredentialsValidator.apiId("1234567"), 1_234_567)
        XCTAssertEqual(CredentialsValidator.apiId(" 42 "), 42)
    }

    func testApiIdRejectsBadInput() {
        for text in ["", "0", "-5", "12a4", "1.5", "+7", "١٢٣"] {
            XCTAssertNil(CredentialsValidator.apiId(text), text)
        }
    }

    func testApiHashNeeds32HexCharacters() {
        XCTAssertTrue(CredentialsValidator.isValidApiHash("0123456789abcdefABCDEF0123456789"))
        XCTAssertTrue(CredentialsValidator.isValidApiHash(" 0123456789abcdef0123456789abcdef "))
    }

    func testApiHashRejectsBadInput() {
        XCTAssertFalse(CredentialsValidator.isValidApiHash(""))
        XCTAssertFalse(CredentialsValidator.isValidApiHash("0123456789abcdef0123456789abcde"))
        XCTAssertFalse(CredentialsValidator.isValidApiHash("0123456789abcdef0123456789abcdef0"))
        XCTAssertFalse(CredentialsValidator.isValidApiHash("0123456789abcdef0123456789abcdeg"))
    }
}
