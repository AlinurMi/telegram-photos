import ActivityKit
import Foundation
import Observation

/// Finds the embedded widget extension, for the install info.
enum SpikeIdentifiers {
    static var widgetBundleID: String? {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
            let urls = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
        else { return nil }
        return urls.filter { $0.pathExtension == "appex" }.compactMap { Bundle(url: $0)?.bundleIdentifier }.first
    }
}

/// What the demo is doing right now, shown on the debug screen.
@MainActor
@Observable
final class SpikeModel {
    static let shared = SpikeModel()

    var liveActivityStatus = "Not started"

    private var activity: Activity<SyncActivityAttributes>?

    func startLiveActivityDemo() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveActivityStatus = "Live Activities are turned off for this app"
            return
        }
        let total = 60
        let attributes = SyncActivityAttributes()
        let first = SyncActivityAttributes.ContentState(
            done: 0, total: total, currentFileName: "IMG_0001.HEIC",
            bytesRemaining: 60_000_000, uploadedBytes: 0, finished: false)
        do {
            let started = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: first, staleDate: nil),
                pushType: nil)
            activity = started
            liveActivityStatus = "Running"
            Task { await runLiveActivity(started, total: total) }
        } catch {
            liveActivityStatus = "Could not start: \(error)"
        }
    }

    private func runLiveActivity(_ activity: Activity<SyncActivityAttributes>, total: Int) async {
        for n in 1...total {
            try? await Task.sleep(for: .seconds(1))
            let state = SyncActivityAttributes.ContentState(
                done: n, total: total, currentFileName: String(format: "IMG_%04d.HEIC", n),
                bytesRemaining: Int64(total - n) * 1_000_000, uploadedBytes: Int64(n) * 1_000_000,
                finished: false)
            await activity.update(ActivityContent(state: state, staleDate: nil))
            liveActivityStatus = "Running \(n)/\(total)"
        }
        let final = SyncActivityAttributes.ContentState(
            done: total, total: total, currentFileName: nil,
            bytesRemaining: 0, uploadedBytes: Int64(total) * 1_000_000, finished: true)
        await activity.end(
            ActivityContent(state: final, staleDate: nil),
            dismissalPolicy: .after(.now + 300))
        liveActivityStatus = "Finished"
    }
}
