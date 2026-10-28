import Foundation
import Network
import SyncCore
import UIKit
import os

/// Reports network, charging and free-storage conditions for the sync engine.
///
/// Create one per process: it keeps a single `NWPathMonitor` running.
final class SystemEnvironment: EnvironmentProbe, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let latestPath = OSAllocatedUnfairLock<NWPath?>(initialState: nil)
    private let firstPathTimeout: TimeInterval
    private let logger: FileLogger

    init(firstPathTimeout: TimeInterval = 1.0, logger: FileLogger = .shared) {
        self.firstPathTimeout = firstPathTimeout
        self.logger = logger

        let latestPath = self.latestPath
        monitor.pathUpdateHandler = { path in
            latestPath.withLock { $0 = path }
        }
        monitor.start(queue: DispatchQueue(label: "SystemEnvironment.path"))

        // Battery state reads as unknown until monitoring has been on for a moment.
        Task { @MainActor in
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
    }

    deinit {
        monitor.cancel()
    }

    func networkState() async -> NetworkState {
        let deadline = Date().addingTimeInterval(firstPathTimeout)
        var path = latestPath.withLock { $0 }
        while path == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            path = latestPath.withLock { $0 }
        }
        guard let path else { return .unavailable }
        return Self.networkState(status: path.status, isExpensive: path.isExpensive)
    }

    func isCharging() async -> Bool {
        await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            return Self.isCharging(UIDevice.current.batteryState)
        }
    }

    func freeDiskBytes() async -> Int64 {
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            // 0 makes the engine wait rather than risk filling the phone.
            let nsError = error as NSError
            logger.warning("Free space check failed: \(nsError.domain) \(nsError.code)", category: "environment")
            return 0
        }
    }

    static func networkState(status: NWPath.Status, isExpensive: Bool) -> NetworkState {
        guard status != .unsatisfied else { return .unavailable }
        return isExpensive ? .expensive : .ok
    }

    static func isCharging(_ state: UIDevice.BatteryState) -> Bool {
        state == .charging || state == .full
    }
}
