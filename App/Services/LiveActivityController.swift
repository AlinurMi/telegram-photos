import ActivityKit

import Foundation

import SyncCore

private typealias SyncActivityContent = ActivityContent<SyncActivityAttributes.ContentState>

/// Shows a sync run in the Dynamic Island and on the Lock Screen (D12).
///
/// It stays registered with the coordinator but only acts while armed. Sync Now has the system's own progress
/// UI and overnight runs can't show one, so only Shortcuts-triggered runs arm it (D12 outcome A).
actor LiveActivityController: SyncObserver {
    static let shared = LiveActivityController()

    /// How long an update stays current. If the app is suspended, iOS shows the activity as out of date after this.
    static let staleAfter: TimeInterval = 30
    /// How long the finished state stays visible.
    static let dismissAfter: TimeInterval = 300
    /// The activity ends this long before the run's deadline, so it never outlives the process that updates it.
    static let endBeforeDeadline: TimeInterval = 2

    private let logger: FileLogger
    private var registered = false
    private var armed = false
    private var arming = 0
    private var deadline: Date?
    private var tracker = LiveActivityTracker()
    private var activity: Activity<SyncActivityAttributes>?
    private var watchdog: Task<Void, Never>?

    init(logger: FileLogger = .shared) {
        self.logger = logger
    }

    /// Shows the next sync run, if it has anything to upload. Call right before `sync`, and `disarm()` after it.
    ///
    /// With a `deadline`, the activity ends shortly before it even if the run is still going.
    func arm(deadline: Date?) async {
        if !registered {
            registered = true
            let coordinator = await SyncCoordinator.shared
            await coordinator.addObserver(self)
        }
        await endLeftovers()
        arming += 1
        armed = true
        self.deadline = deadline
        tracker = LiveActivityTracker()
        scheduleWatchdog(arming)
    }

    /// Stops following runs, and ends the activity if the run didn't end it.
    func disarm() async {
        armed = false
        watchdog?.cancel()
        watchdog = nil
        if let final = tracker.expire() {
            await end(final)
        }
        tracker = LiveActivityTracker()
    }

    /// Ends activities left by a process that was killed mid-run; they'd otherwise sit frozen on screen.
    func endLeftovers() async {
        var ended = 0
        for leftover in Activity<SyncActivityAttributes>.activities where leftover.id != activity?.id {
            guard leftover.activityState == .active || leftover.activityState == .stale else { continue }
            await leftover.end(nil, dismissalPolicy: .immediate)
            ended += 1
        }
        if ended > 0 {
            logger.info("Ended \(ended) leftover Live Activities", category: "liveactivity")
        }
    }

    func handle(_ event: SyncEvent) async {
        guard armed else { return }
        switch tracker.apply(event, now: Date()) {
        case .none:
            return
        case .start(let state):
            start(state)
        case .update(let state):
            await activity?.update(content(state))
        case .end(let state):
            await end(state)
        }
    }

    private func start(_ state: SyncActivityAttributes.ContentState) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activity not shown: turned off for this app", category: "liveactivity")
            tracker.abandon()
            return
        }
        if Activity<SyncActivityAttributes>.activities.contains(where: { $0.activityState == .active }) {
            logger.info("Live Activity not shown: another one is running", category: "liveactivity")
            tracker.abandon()
            return
        }
        do {
            activity = try Activity.request(
                attributes: SyncActivityAttributes(), content: content(state), pushType: nil)
            logger.info("Live Activity started for \(state.total) items", category: "liveactivity")
        } catch {
            logger.warning("Live Activity could not start: \(error)", category: "liveactivity")
            tracker.abandon()
        }
    }

    private func end(_ state: SyncActivityAttributes.ContentState) async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(Self.dismissAfter)))
        logger.info("Live Activity finished: \(state.done) uploaded", category: "liveactivity")
    }

    private func content(_ state: SyncActivityAttributes.ContentState) -> SyncActivityContent {
        var staleDate = Date().addingTimeInterval(Self.staleAfter)
        if let deadline, deadline < staleDate {
            staleDate = deadline
        }
        return ActivityContent(state: state, staleDate: staleDate)
    }

    private func scheduleWatchdog(_ thisArming: Int) {
        watchdog?.cancel()
        watchdog = nil
        guard let deadline else { return }
        let delay = deadline.timeIntervalSinceNow - Self.endBeforeDeadline
        watchdog = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self.expire(thisArming)
        }
    }

    private func expire(_ thisArming: Int) async {
        guard thisArming == arming, armed, let final = tracker.expire() else { return }
        logger.info("Live Activity ended at the time limit", category: "liveactivity")
        await end(final)
    }
}

/// Turns sync events into Live Activity content and decides when iOS gets an update (D12).
///
/// Kept apart from ActivityKit so it can be tested.
struct LiveActivityTracker {
    typealias State = SyncActivityAttributes.ContentState

    enum Action: Equatable {
        case none
        case start(State)
        case update(State)
        case end(State)
    }

    /// Progress updates closer together than this are skipped. A finished item always updates.
    static let minimumUpdateInterval: TimeInterval = 2

    /// Whether a run with something to upload is being shown.
    private(set) var isShowing = false
    private var total = 0
    private var handled = 0
    private var uploaded = 0
    private var totalBytes: Int64 = 0
    /// Bytes of handled items whose size was known up front, whatever their outcome.
    private var handledBytes: Int64 = 0
    private var uploadedBytes: Int64 = 0
    private var currentIndex: Int?
    private var currentFileName: String?
    private var currentKnownBytes: Int64?
    private var currentReportedBytes: Int64 = 0
    private var currentSent: Int64 = 0
    private var lastPush: Date?

    mutating func apply(_ event: SyncEvent, now: Date) -> Action {
        switch event {
        case .runStarted(let total, let totalBytes):
            self = LiveActivityTracker()
            guard total > 0 else { return .none }
            isShowing = true
            self.total = total
            self.totalBytes = max(0, totalBytes)
            lastPush = now
            return .start(state)
        case .unitStarted(let index, let total, let fileName, let bytes):
            guard isShowing else { return .none }
            self.total = total
            handled = index
            currentIndex = index
            currentFileName = fileName
            currentKnownBytes = bytes
            currentReportedBytes = 0
            currentSent = 0
            return throttled(now)
        case .unitProgress(let sent, let size):
            guard isShowing, currentIndex != nil else { return .none }
            currentSent = max(0, sent)
            currentReportedBytes = max(0, size)
            return throttled(now)
        case .unitFinished(let index, let total, let status):
            guard isShowing else { return .none }
            self.total = total
            if index == currentIndex {
                handledBytes += currentKnownBytes ?? 0
                if status == .done {
                    uploadedBytes += currentKnownBytes ?? currentReportedBytes
                }
            }
            if status == .done {
                uploaded += 1
            }
            handled = index + 1
            clearCurrent()
            lastPush = now
            return .update(state)
        case .runFinished(let report):
            guard isShowing else { return .none }
            isShowing = false
            clearCurrent()
            uploaded = report.uploaded
            return .end(finalState)
        }
    }

    /// Stops showing the run (time limit, or the caller is done) and returns the finished state, if it was showing.
    mutating func expire() -> State? {
        guard isShowing else { return nil }
        isShowing = false
        clearCurrent()
        return finalState
    }

    /// Forgets the run, e.g. because iOS refused to start the activity.
    mutating func abandon() {
        self = LiveActivityTracker()
    }

    private mutating func throttled(_ now: Date) -> Action {
        if let lastPush, now.timeIntervalSince(lastPush) < Self.minimumUpdateInterval {
            return .none
        }
        lastPush = now
        return .update(state)
    }

    private mutating func clearCurrent() {
        currentIndex = nil
        currentFileName = nil
        currentKnownBytes = nil
        currentReportedBytes = 0
        currentSent = 0
    }

    private var bytesRemaining: Int64 {
        var sent: Int64 = 0
        if let known = currentKnownBytes {
            sent = min(currentSent, known)
        }
        return max(0, totalBytes - handledBytes - sent)
    }

    private var state: State {
        State(
            done: min(handled, total), total: total, currentFileName: currentFileName,
            bytesRemaining: bytesRemaining, uploadedBytes: uploadedBytes, finished: false)
    }

    private var finalState: State {
        State(
            done: uploaded, total: total, currentFileName: nil,
            bytesRemaining: bytesRemaining, uploadedBytes: uploadedBytes, finished: true)
    }
}
