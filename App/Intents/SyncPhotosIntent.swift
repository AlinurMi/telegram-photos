import AppIntents
import Foundation
import SyncCore
import UIKit

/// The Shortcuts action the owner's automations run. Syncs in the background within a time budget.
///
/// It's a `LiveActivityIntent`, so it may start the Live Activity without opening the app.
struct SyncPhotosIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Sync Photos"
    static let description: IntentDescription? = IntentDescription("Uploads new photos and videos to Telegram.")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let report = await IntentSync.run()
        return .result(dialog: IntentDialog(stringLiteral: SyncIntentDialog.text(for: report)))
    }
}

/// One Shortcuts-triggered run: Live Activity, sync with a deadline, then the overnight request.
@MainActor
enum IntentSync {
    private static let logger = FileLogger.shared

    /// Returns the run's report, or `nil` if a sync was already running.
    static func run() async -> SyncReport? {
        let budget = AppSettings.shared.intentBudgetSeconds
        let deadline = Date().addingTimeInterval(budget)
        logger.info(
            "Intent started: budget \(Int(budget)) s, protected data available: \(protectedDataAvailable)",
            category: "intent")
        IntentHeartbeat.start()

        let coordinator = SyncCoordinator.shared
        let liveActivity = LiveActivityController.shared
        await liveActivity.arm(deadline: deadline)
        let report = await coordinator.sync(trigger: .intent, deadline: deadline, allowCellular: false)
        await liveActivity.disarm()
        BackgroundSync.scheduleBackfill()

        let outcome = report == nil ? "already syncing" : "ran"
        logger.info(
            "Intent finished: \(outcome), protected data available: \(protectedDataAvailable)", category: "intent")
        return report
    }

    private static var protectedDataAvailable: Bool {
        UIApplication.shared.isProtectedDataAvailable
    }
}

/// Logs "intent alive t=<seconds>" every 5 s, so the logs show how long iOS keeps the app running
/// after an automation starts it. It keeps going after the intent returns, for up to 3 minutes.
@MainActor
enum IntentHeartbeat {
    static let interval: TimeInterval = 5
    static let maximumDuration: TimeInterval = 180
    /// A tick this late means the app was suspended in between, so the measurement ends there.
    static let suspendedGap: TimeInterval = 15

    private static var task: Task<Void, Never>?

    /// Starts a fresh heartbeat, replacing one that's still running.
    static func start() {
        task?.cancel()
        let logger = FileLogger.shared
        let startedAt = Date()
        task = Task {
            var lastTick = startedAt
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                let now = Date()
                let gap = now.timeIntervalSince(lastTick)
                if gap > suspendedGap {
                    logger.info(
                        "intent heartbeat stopped: app was suspended for about \(Int(gap)) s", category: "intent")
                    return
                }
                lastTick = now
                let elapsed = now.timeIntervalSince(startedAt)
                logger.info("intent alive t=\(Int(elapsed.rounded()))", category: "intent")
                if elapsed >= maximumDuration { return }
            }
        }
    }
}

/// What the Shortcuts action says when it ends, e.g. "Uploaded 5, 12 waiting."
enum SyncIntentDialog {
    static func text(for report: SyncReport?) -> String {
        guard let report else { return "Already syncing." }
        let uploaded = report.uploaded > 0 ? "Uploaded \(report.uploaded.formatted()). " : ""
        switch report.blockedBy {
        case nil, .deadline?:
            if report.uploaded == 0 && report.failed == 0 && report.remainingEligible == 0 { return "Up to date." }
            var parts = ["Uploaded \(report.uploaded.formatted())"]
            if report.remainingEligible > 0 { parts.append("\(report.remainingEligible.formatted()) waiting") }
            if report.failed > 0 { parts.append("\(report.failed.formatted()) failed") }
            return parts.joined(separator: ", ") + "."
        case .cancelled?: return uploaded + "Stopped."
        case .noNetwork?: return uploaded + "Waiting for internet."
        case .expensiveNetwork?: return uploaded + "Waiting for Wi-Fi."
        case .needsCharger?: return uploaded + "Older items will upload while charging."
        case .authLost?: return "Open TelegramPhotos and log in again."
        case .noLibraryAccess?: return "Open TelegramPhotos and allow full Photos access."
        case .lowDisk?: return uploaded + "Free up space on your iPhone."
        }
    }
}
