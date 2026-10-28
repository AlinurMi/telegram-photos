import SwiftUI
import SyncCore

/// Where backups go, what gets uploaded, the version, and the maintenance tools under a collapsed Advanced.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.includeScreenshotsKey) private var includeScreenshots = true
    @State private var destinationTitle: String?
    @State private var showAdvanced = false
    @State private var logURLs: [URL] = []
    @State private var details = AdvancedDetails()
    @State private var confirming: MaintenanceAction?
    @State private var working: MaintenanceAction?
    @State private var resultText: String?

    var body: some View {
        Form {
            backupSection
            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    advancedContent
                }
            }
        }
        .navigationTitle("Settings")
        .task { await load() }
        .confirmationDialog(
            confirming?.question ?? "",
            isPresented: isConfirming,
            titleVisibility: .visible,
            presenting: confirming
        ) { action in
            Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) { run(action) }
        } message: { action in
            Text(action.explanation)
        }
        .alert(resultText ?? "", isPresented: isShowingResult) {
            Button("OK", role: .cancel) {}
        }
    }

    private var backupSection: some View {
        Section("Backup") {
            NavigationLink {
                ChangeDestinationView()
            } label: {
                LabeledContent("Destination", value: destinationTitle ?? "Not chosen")
            }
            Toggle("Include screenshots & screen recordings", isOn: $includeScreenshots)
            Toggle(isOn: .constant(false)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Re-send edited photos")
                    Text("Coming soon")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(true)
        }
    }

    @ViewBuilder private var advancedContent: some View {
        let isBusy = working != nil || model.isSyncing
        if logURLs.isEmpty {
            Text("No logs yet").foregroundStyle(.secondary)
        } else {
            ShareLink(items: logURLs) {
                Label("Share logs", systemImage: "square.and.arrow.up")
            }
        }
        actionButton(.rebuild, title: "Rebuild from channel", isBusy: isBusy)
        actionButton(.retryFailed, title: "Retry failed (\(model.counts.failed.formatted()))", isBusy: isBusy)
            .disabled(model.counts.failed == 0)
        rawCounters
        LabeledContent(
            "baseline", value: details.baselineDate?.formatted(date: .abbreviated, time: .shortened) ?? "none")
        VStack(alignment: .leading, spacing: 6) {
            Text("last report")
            Text(details.lastReportJSON ?? "none")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        NavigationLink("Debug spike screen") { SpikeView() }
        actionButton(.logOut, title: "Log out of Telegram", isBusy: isBusy)
        actionButton(.reset, title: "Reset sync state", isBusy: isBusy)
    }

    @ViewBuilder private var rawCounters: some View {
        let counts = model.counts
        Group {
            LabeledContent("done", value: counts.done.formatted())
            LabeledContent("pending", value: counts.pending.formatted())
            LabeledContent("uploading", value: counts.uploading.formatted())
            LabeledContent("failed", value: counts.failed.formatted())
            LabeledContent("skipped", value: counts.skipped.formatted())
            LabeledContent("backfill pending", value: counts.backfillPending.formatted())
        }
        .font(.footnote.monospacedDigit())
    }

    private func actionButton(_ action: MaintenanceAction, title: String, isBusy: Bool) -> some View {
        Button(role: action.isDestructive ? .destructive : nil) {
            if action.needsConfirmation {
                confirming = action
            } else {
                run(action)
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if working == action { ProgressView() }
            }
        }
        .disabled(isBusy)
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var isShowingResult: Binding<Bool> {
        Binding(get: { resultText != nil }, set: { if !$0 { resultText = nil } })
    }

    private func load() async {
        destinationTitle = AppSettings.shared.destinationTitle
        let coordinator = SyncCoordinator.shared
        await coordinator.refreshState()
        details = await coordinator.advancedDetails()
        await log.flush()
        logURLs = await log.exportURLs()
    }

    private func run(_ action: MaintenanceAction) {
        guard working == nil else { return }
        working = action
        Task {
            let coordinator = SyncCoordinator.shared
            do {
                switch action {
                case .rebuild:
                    let count = try await coordinator.rebuild()
                    resultText = SettingsText.rebuilt(count)
                case .retryFailed:
                    let count = try await coordinator.retryFailed()
                    resultText = SettingsText.retried(count)
                case .logOut:
                    // Setup takes over the whole screen once this finishes.
                    try await coordinator.logOut()
                case .reset:
                    try await coordinator.resetState()
                    resultText = "Sync state reset"
                }
            } catch {
                log.warning("\(action.rawValue) failed: \(type(of: error))", category: "settings")
                resultText = SettingsText.failure(error)
            }
            details = await coordinator.advancedDetails()
            working = nil
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// The destination picker from setup, going back to Settings once a chat is chosen.
private struct ChangeDestinationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DestinationView(telegram: .shared, onChosen: { dismiss() })
    }
}

/// The Advanced actions that change state.
enum MaintenanceAction: String {
    case rebuild, retryFailed, logOut, reset

    var needsConfirmation: Bool { self != .retryFailed }

    var isDestructive: Bool { self == .logOut || self == .reset }

    var question: String {
        switch self {
        case .rebuild: return "Rebuild from channel?"
        case .retryFailed: return "Retry failed items?"
        case .logOut: return "Log out of Telegram?"
        case .reset: return "Reset sync state?"
        }
    }

    var explanation: String {
        switch self {
        case .rebuild:
            return "Reads the backup chat and marks every photo already there as uploaded. Useful after reinstalling."
        case .retryFailed:
            return "Failed items will be tried again on the next sync."
        case .logOut:
            return "You'll need to log in and choose where backups go again. Nothing already uploaded is lost."
        case .reset:
            return "Everything will be uploaded again unless you run Rebuild from channel afterwards."
        }
    }

    var confirmTitle: String {
        switch self {
        case .rebuild: return "Rebuild"
        case .retryFailed: return "Retry"
        case .logOut: return "Log Out"
        case .reset: return "Reset"
        }
    }
}

/// Result and error lines for the Advanced actions. Kept apart from the view so they can be tested.
enum SettingsText {
    static func rebuilt(_ count: Int) -> String {
        "Marked \(items(count)) as already uploaded"
    }

    static func retried(_ count: Int) -> String {
        "\(items(count)) will be tried again"
    }

    static func failure(_ error: Error) -> String {
        if let error = error as? CoordinatorError, error == .busy {
            return "A sync is running. Try again when it's done."
        }
        if let error = error as? UploadError {
            switch error.kind {
            case .authLost: return "Log in to Telegram first."
            case .cancelled: return "Stopped."
            default: return "Couldn't reach Telegram. Try again."
            }
        }
        if let error = error as? TelegramError {
            return error.message
        }
        return "Something went wrong. Share logs for details."
    }

    private static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }
}
