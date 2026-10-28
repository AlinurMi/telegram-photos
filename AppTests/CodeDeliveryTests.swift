import XCTest

@testable import TelegramPhotos

final class CodeDeliveryTests: XCTestCase {
    func testTelegramMessageMapsToTelegramApp() {
        XCTAssertEqual(CodeDelivery.Method(typeName: "authenticationCodeTypeTelegramMessage"), .telegramApp)
    }

    func testSmsVariantsMapToSms() {
        for name in ["authenticationCodeTypeSms", "authenticationCodeTypeSmsWord", "authenticationCodeTypeSmsPhrase"] {
            XCTAssertEqual(CodeDelivery.Method(typeName: name), .sms)
        }
    }

    func testCallMapsToCall() {
        XCTAssertEqual(CodeDelivery.Method(typeName: "authenticationCodeTypeCall"), .call)
    }

    func testMethodsTheAppCannotReceiveAreUnreachable() {
        for name in [
            "authenticationCodeTypeFirebaseIos", "authenticationCodeTypeFirebaseAndroid",
            "authenticationCodeTypeFragment", "authenticationCodeTypeMissedCall", "authenticationCodeTypeFlashCall",
        ] {
            XCTAssertEqual(CodeDelivery.Method(typeName: name), .unreachable, name)
        }
    }
}
