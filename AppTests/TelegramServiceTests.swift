import SyncCore

import XCTest

@testable import TelegramPhotos

final class TelegramServiceTests: XCTestCase {
    func testWaitingStatesMapToSetupSteps() {
        XCTAssertEqual(AuthStep.step(forStateName: "authorizationStateWaitPhoneNumber"), .waitingForPhone)
        XCTAssertEqual(AuthStep.step(forStateName: "authorizationStateWaitCode"), .waitingForCode)
        XCTAssertEqual(AuthStep.step(forStateName: "authorizationStateWaitPassword"), .waitingForPassword)
        XCTAssertEqual(AuthStep.step(forStateName: "authorizationStateReady"), .ready)
    }

    func testLogoutAndClosedMapToLoggedOut() {
        XCTAssertEqual(AuthStep.step(forStateName: "authorizationStateLoggingOut"), .loggedOut)
        XCTAssertEqual(AuthStep.step(forStateName: "authorizationStateClosing"), .loggedOut)
        XCTAssertEqual(AuthStep.step(forStateName: "authorizationStateClosed"), .loggedOut)
    }

    func testOtherStatesAreUnsupported() {
        for name in [
            "authorizationStateWaitEmailAddress",
            "authorizationStateWaitEmailCode",
            "authorizationStateWaitRegistration",
            "authorizationStateWaitOtherDeviceConfirmation",
            "authorizationStateWaitPremiumPurchase",
        ] {
            XCTAssertEqual(AuthStep.step(forStateName: name), .unsupported(name))
        }
    }

    func testWrongCodeMessage() {
        XCTAssertEqual(TDLibErrorMapping.readableMessage(code: 400, message: "PHONE_CODE_INVALID"), "Wrong code")
    }

    func testWrongPasswordMessage() {
        XCTAssertEqual(
            TDLibErrorMapping.readableMessage(code: 400, message: "PASSWORD_HASH_INVALID"),
            "Wrong password"
        )
    }

    func testRateLimitMessages() {
        let expected = "Too many attempts. Wait a few minutes and try again."
        XCTAssertEqual(TDLibErrorMapping.readableMessage(code: 420, message: "FLOOD_WAIT_30"), expected)
        XCTAssertEqual(TDLibErrorMapping.readableMessage(code: 429, message: "Too Many Requests"), expected)
    }

    func testUnknownErrorKeepsTelegramText() {
        XCTAssertEqual(
            TDLibErrorMapping.readableMessage(code: 400, message: "SOMETHING_NEW"),
            "Telegram error: SOMETHING_NEW"
        )
    }

    @MainActor
    func testStartWithoutCredentialsNeedsCredentials() {
        let service = TelegramService(
            keychain: KeychainStore(service: "test.telegramservice.\(UUID().uuidString)"),
            logger: FileLogger(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            rootDirectory: FileManager.default.temporaryDirectory
        )
        service.start()
        XCTAssertEqual(service.step, .needsCredentials)
    }

    @MainActor
    func testWaitUntilReadyWithoutCredentialsThrowsAuthLost() async {
        let service = TelegramService(
            keychain: KeychainStore(service: "test.telegramservice.\(UUID().uuidString)"),
            logger: FileLogger(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            rootDirectory: FileManager.default.temporaryDirectory
        )
        do {
            try await service.waitUntilReady(timeout: 1)
            XCTFail("Expected an error")
        } catch let error as UploadError {
            XCTAssertEqual(error.kind, .authLost)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
