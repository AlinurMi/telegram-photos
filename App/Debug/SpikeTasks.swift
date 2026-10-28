import ActivityKit
import BackgroundTasks
import Foundation
import Observation

/// Task identifiers come from Info.plist so they follow whatever the build declares (D4).
enum SpikeIdentifiers {
    static var permitted: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }

    static var syncNow: String? {
        permitted.first { $0.hasSuffix(".syncnow") }
    }

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

    var lastSubmitError: String?
    var backgroundStatus = "Not started"
    var liveActivityStatus = "Not started"

    private var activity: Activity<SyncActivityAttributes>?

    func submitBackgroundDemo() {
        lastSubmitError = nil
        guard let identifier = SpikeIdentifiers.syncNow else {
            lastSubmitError = "No .syncnow identifier in Info.plist"
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Syncing photos",
            subtitle: "About to start…"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            backgroundStatus = "Submitted, waiting for iOS to start it"
        } catch {
            lastSubmitError = String(describing: error)
            backgroundStatus = "Submit failed"
        }
    }

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

    func backgroundTaskStarted() {
        backgroundStatus = "Started by iOS"
    }

    func backgroundTaskTick(_ n: Int) {
        backgroundStatus = "Running \(n)/60"
    }

    func backgroundTaskEnded(success: Bool) {
        backgroundStatus = success ? "Finished" : "Stopped early (cancelled or expired)"
    }
}

enum SpikeTasks {
    /// Registers the demo launch handler. Must be called before the app finishes launching.
    static func registerSyncNow() {
        guard let identifier = SpikeIdentifiers.syncNow else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            run(task)
        }
    }

    private static func run(_ task: BGContinuedProcessingTask) {
        let work = Task { () -> Bool in
            await SpikeModel.shared.backgroundTaskStarted()
            let progress = task.progress
            progress.totalUnitCount = 60
            for n in 1...60 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return false }
                progress.completedUnitCount = Int64(n)
                task.updateTitle("Syncing photos", subtitle: "\(n)/60")
                await SpikeModel.shared.backgroundTaskTick(n)
            }
            return true
        }
        task.expirationHandler = { work.cancel() }
        Task {
            let success = await work.value
            await SpikeModel.shared.backgroundTaskEnded(success: success)
            task.setTaskCompleted(success: success)
        }
    }
}
