import Network
import SyncCore
import UIKit
import XCTest

@testable import TelegramPhotos

final class SystemEnvironmentTests: XCTestCase {
    func testNetworkStateMapping() {
        XCTAssertEqual(SystemEnvironment.networkState(status: .unsatisfied, isExpensive: false), .unavailable)
        XCTAssertEqual(SystemEnvironment.networkState(status: .unsatisfied, isExpensive: true), .unavailable)
        XCTAssertEqual(SystemEnvironment.networkState(status: .satisfied, isExpensive: true), .expensive)
        XCTAssertEqual(SystemEnvironment.networkState(status: .satisfied, isExpensive: false), .ok)
    }

    func testChargingMapping() {
        XCTAssertTrue(SystemEnvironment.isCharging(.charging))
        XCTAssertTrue(SystemEnvironment.isCharging(.full))
        XCTAssertFalse(SystemEnvironment.isCharging(.unplugged))
        XCTAssertFalse(SystemEnvironment.isCharging(.unknown))
    }

    func testFreeDiskIsPositive() async {
        let free = await SystemEnvironment().freeDiskBytes()
        XCTAssertGreaterThan(free, 0)
    }

    func testNetworkStateReturnsWithinTimeout() async {
        let start = Date()
        _ = await SystemEnvironment(firstPathTimeout: 1.0).networkState()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)
    }

    func testSystemClockIsCurrent() {
        XCTAssertLessThan(abs(SystemClock().now().timeIntervalSinceNow), 1.0)
    }
}

final class MapKitPlaceResolverTests: XCTestCase {
    func testFormatsCityAndCountry() {
        XCTAssertEqual(MapKitPlaceResolver.format(city: "Paris", country: "France"), "Paris, France")
    }

    func testFallsBackToCountryOrCity() {
        XCTAssertEqual(MapKitPlaceResolver.format(city: nil, country: "France"), "France")
        XCTAssertEqual(MapKitPlaceResolver.format(city: "  ", country: "France"), "France")
        XCTAssertEqual(MapKitPlaceResolver.format(city: "Paris", country: nil), "Paris")
    }

    func testReturnsNilWhenNothingKnown() {
        XCTAssertNil(MapKitPlaceResolver.format(city: nil, country: nil))
        XCTAssertNil(MapKitPlaceResolver.format(city: "", country: " "))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(MapKitPlaceResolver.format(city: " Oslo ", country: "Norway\n"), "Oslo, Norway")
    }

    func testThrottleSpacesCalls() async {
        let throttle = RequestThrottle(interval: 0.2)
        let start = Date()
        await throttle.wait()
        await throttle.wait()
        await throttle.wait()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.35)
    }
}
