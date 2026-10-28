import BackgroundTasks

import Foundation

/// Runs Sync Now as a continued background task, so uploading goes on after the owner leaves the app
/// and iOS shows the progress in the Dynamic Island and on the Lock Screen.
///
/// Named `BackgroundSync` rather than `BackgroundTasks` so it doesn't hide Apple's module of that name.
import SyncCore

/// Feeds sync events into the running continued task's progress and subtitle.
///
/// It stays registered with the coordinator; events are ignored while no task is attached.

/// What the system's progress UI shows during Sync Now. Kept apart from the task so it can be tested.
@MainActor
final class BackgroundSync {
    static let shared = BackgroundSync()

    /// How long to wait for iOS to start a submitted task before syncing in the foreground instead.
    private static let startTimeout: Duration = .seconds(5)

    private enum SyncNowState {
        case idle, submitted, running
    }

    private var syncNowState = SyncNowState.idle
    private var submission = 0
    private var allowCellular = false
    private var observerAttached = false
    private let progress = ContinuedTaskProgress()
    private let logger = FileLogger.shared

    /// Task identifiers come from Info.plist, because SideStore rewrites them with the bundle ID (D4).
    nonisolated static var permittedIdentifiers: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }

    nonisolated static var syncNowIdentifier: String? {
        permittedIdentifiers.first { $0.hasSuffix(".syncnow") }
    }

    /// Registers the Sync Now handler. Call once, before the app finishes launching.
    func register() {
        guard let identifier = Self.syncNowIdentifier else {
            logger.error("No .syncnow task identifier in Info.plist", category: "background")
            return
        }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in await BackgroundSync.shared.runSyncNow(task) }
        }
        if !registered {
            logger.error("Could not register the Sync Now task", category: "background")
        }
    }

    /// Starts Sync Now. Asks iOS for a continued task; if it says no, syncs in the foreground instead.
    func startSyncNow(allowCellular: Bool) {
        guard syncNowState == .idle else {
            logger.info("Sync Now ignored: a background sync is already running", category: "background")
            return
        }
        guard let identifier = Self.syncNowIdentifier else {
            logger.warning("Sync Now in the foreground: no task identifier", category: "background")
            syncInForeground(allowCellular: allowCellular)
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: ContinuedSyncDisplay.title,
            subtitle: ContinuedSyncDisplay.startingSubtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            let nsError = error as NSError
            logger.warning(
                "Sync Now in the foreground: task refused (\(nsError.domain) \(nsError.code))", category: "background")
            syncInForeground(allowCellular: allowCellular)
            return
        }
        self.allowCellular = allowCellular
        syncNowState = .submitted
        submission += 1
        let thisSubmission = submission
        Task {
            try? await Task.sleep(for: Self.startTimeout)
            fallBackIfNotStarted(thisSubmission)
        }
    }

    private func fallBackIfNotStarted(_ thisSubmission: Int) {
        guard submission == thisSubmission, syncNowState == .submitted else { return }
        syncNowState = .idle
        logger.warning("Sync Now in the foreground: iOS did not start the task", category: "background")
        syncInForeground(allowCellular: allowCellular)
    }

    private func syncInForeground(allowCellular: Bool) {
        Task { _ = await SyncCoordinator.shared.sync(trigger: .manual, deadline: nil, allowCellular: allowCellular) }
    }

    private func runSyncNow(_ task: BGContinuedProcessingTask) async {
        syncNowState = .running
        let coordinator = SyncCoordinator.shared
        task.expirationHandler = {
            Task { await coordinator.cancelCurrentRun() }
        }
        if !observerAttached {
            observerAttached = true
            await coordinator.addObserver(progress)
        }
        progress.attach(task)
        logger.info("Sync Now running as a background task", category: "background")

        let report = await coordinator.sync(trigger: .manual, deadline: nil, allowCellular: allowCellular)

        progress.detach()
        let success = Self.succeeded(report)
        task.setTaskCompleted(success: success)
        logger.info("Sync Now background task ended, success: \(success)", category: "background")
        allowCellular = false
        syncNowState = .idle
    }

    /// `nil` means another run was already going, which the task leaves alone.
    nonisolated static func succeeded(_ report: SyncReport?) -> Bool {
        guard let report else { return true }
        return report.blockedBy == nil || report.blockedBy == .deadline
    }
}
final class ContinuedTaskProgress: SyncObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var display = ContinuedSyncDisplay()
    private var shownSubtitle: String?

    func attach(_ task: BGContinuedProcessingTask) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        display = ContinuedSyncDisplay()
        shownSubtitle = nil
        show(on: task)
    }

    func detach() {
        lock.lock()
        defer { lock.unlock() }
        task = nil
    }

    func handle(_ event: SyncEvent) async {
        lock.lock()
        defer { lock.unlock() }
        guard let task else { return }
        display.apply(event)
        show(on: task)
    }

    private func show(on task: BGContinuedProcessingTask) {
        let progress = task.progress
        progress.totalUnitCount = display.totalUnitCount
        progress.completedUnitCount = display.completedUnitCount
        let subtitle = display.subtitle
        if subtitle != shownSubtitle {
            shownSubtitle = subtitle
            task.updateTitle(ContinuedSyncDisplay.title, subtitle: subtitle)
        }
    }
}
struct ContinuedSyncDisplay: Equatable {
    static let title = "Backing up photos"
    static let startingSubtitle = "Checking for new photos…"
    /// Progress steps per item, so a long video still moves the bar and iOS doesn't think it's stuck.
    static let stepsPerItem: Int64 = 1_000

    private var total = 0
    private var done = 0
    private var fileName: String?
    private var fileFraction = 0.0
    private var started = false
    private var report: SyncReport?

    mutating func apply(_ event: SyncEvent) {
        switch event {
        case .runStarted(let total, _):
            started = true
            self.total = total
        case .unitStarted(let index, let total, let fileName, _):
            started = true
            done = index
            self.total = total
            self.fileName = fileName
            fileFraction = 0
        case .unitProgress(let sent, let size):
            guard size > 0 else { return }
            fileFraction = min(1, max(0, Double(sent) / Double(size)))
        case .unitFinished(let index, let total, _):
            done = index + 1
            self.total = total
            fileName = nil
            fileFraction = 0
        case .runFinished(let report):
            self.report = report
            fileName = nil
            fileFraction = 0
        }
    }

    var totalUnitCount: Int64 {
        Int64(max(total, 1)) * Self.stepsPerItem
    }

    var completedUnitCount: Int64 {
        if let report, report.blockedBy == nil { return totalUnitCount }
        let steps = Int64(min(done, total)) * Self.stepsPerItem + Int64(fileFraction * Double(Self.stepsPerItem))
        return min(steps, totalUnitCount)
    }

    /// "37 of 120 · IMG_1234.HEIC" while uploading; a short result at the end.
    var subtitle: String {
        if let report { return Self.result(report) }
        guard started else { return Self.startingSubtitle }
        guard total > 0 else { return "Nothing new to upload" }
        let current = min(total, max(1, fileName == nil ? done : done + 1))
        let count = "\(current.formatted()) of \(total.formatted())"
        guard let fileName else { return count }
        return "\(count) · \(fileName)"
    }

    private static func result(_ report: SyncReport) -> String {
        switch report.blockedBy {
        case nil, .deadline?:
            if report.uploaded == 0 && report.failed == 0 { return "Up to date" }
            let uploaded = "\(report.uploaded.formatted()) uploaded"
            return report.failed == 0 ? uploaded : "\(uploaded) · \(report.failed.formatted()) failed"
        case .cancelled?: return "Stopped"
        case .noNetwork?: return "Waiting for internet"
        case .expensiveNetwork?: return "Waiting for Wi-Fi"
        case .needsCharger?: return "Older items will upload while charging"
        case .authLost?: return "Log in again"
        case .noLibraryAccess?: return "Full Photos access needed"
        case .lowDisk?: return "Free up space on your iPhone"
        }
    }
}
