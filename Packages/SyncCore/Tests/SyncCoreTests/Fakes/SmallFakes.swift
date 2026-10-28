import Foundation

@testable import SyncCore

/// A mutable `EnvironmentProbe`; defaults describe a good environment (Wi-Fi, charging, plenty of disk).
actor FakeEnvironment: EnvironmentProbe {
    var network: NetworkState
    var charging: Bool
    var freeDisk: Int64

    init(network: NetworkState = .ok, charging: Bool = true, freeDisk: Int64 = 100_000_000_000) {
        self.network = network
        self.charging = charging
        self.freeDisk = freeDisk
    }

    func setNetwork(_ state: NetworkState) { network = state }
    func setCharging(_ value: Bool) { charging = value }
    func setFreeDisk(_ bytes: Int64) { freeDisk = bytes }

    func networkState() async -> NetworkState { network }
    func isCharging() async -> Bool { charging }
    func freeDiskBytes() async -> Int64 { freeDisk }
}

/// Returns scripted place names and counts lookups.
actor FakePlaceResolver: PlaceResolver {
    private var names: [String: String] = [:]
    private(set) var lookups = 0

    init() {}

    func setName(_ name: String?, for coordinate: Coordinate) { names[Self.key(coordinate)] = name }

    func placeName(for coordinate: Coordinate) async -> String? {
        lookups += 1
        return names[Self.key(coordinate)]
    }

    private static func key(_ coordinate: Coordinate) -> String {
        "\(coordinate.latitude),\(coordinate.longitude)"
    }
}

/// A clock that only moves when told to. `Clock.now()` is synchronous, so this is a lock-guarded class
/// rather than an actor.
final class FixedClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { current = start }

    /// Moves the clock forward by `seconds`.
    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    /// Sets the clock to `date`.
    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// Collects every event it receives.
actor RecordingObserver: SyncObserver {
    private(set) var events: [SyncEvent] = []

    init() {}

    func handle(_ event: SyncEvent) async { events.append(event) }
}
