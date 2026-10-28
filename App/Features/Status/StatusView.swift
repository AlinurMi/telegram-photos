import SwiftUI
import SyncCore

/// The main screen: what the sync is doing, the counts and the Sync Now button.
struct StatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let summary = StatusSummary.make(phase: model.phase, counts: model.counts)
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                header(summary)
                if let action = summary.action {
                    actionButton(action)
                }
                CountersRow(counts: model.counts)
                Spacer(minLength: 0)
                PrimaryButton(title: "Sync Now", action: syncNow)
                    .disabled(model.isSyncing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .background { SoftBackdrop() }
            .animation(.smooth, value: summary)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
    }

    private func header(_ summary: StatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.title)
                .font(.largeTitle.bold())
                .contentTransition(.numericText())
            if let progress = summary.progress {
                ProgressView(value: progress)
            }
            if let detail = summary.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(StatusSummary.lastSynced(model.lastSyncAt, now: context.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionButton(_ action: StatusSummary.Action) -> some View {
        Button(action.title) { perform(action) }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
    }

    private func perform(_ action: StatusSummary.Action) {
        switch action {
        case .useCellular:
            model.allowCellularThisRun = true
            syncNow()
        case .logIn:
            Task { await SyncCoordinator.shared.returnToLogin() }
        case .openSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        }
    }

    private func syncNow() {
        BackgroundSync.shared.startSyncNow(allowCellular: model.allowCellularThisRun)
    }
}

/// Uploaded · Queued · Failed. Failed only shows when something failed.
private struct CountersRow: View {
    let counts: StatusCounts

    var body: some View {
        HStack(spacing: 0) {
            Counter(value: counts.done, label: "Uploaded")
            Counter(value: StatusSummary.queued(counts), label: "Queued")
            if counts.failed > 0 {
                Counter(value: counts.failed, label: "Failed")
            }
        }
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// One number with a label under it.
private struct Counter: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value.formatted())
                .font(.title2.bold())
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// What the status screen says, worked out from the model. Kept apart from the view so it can be tested.
struct StatusSummary: Equatable {
    /// The one extra button some states need.
    enum Action: Equatable {
        case useCellular, logIn, openSettings

        var title: String {
            switch self {
            case .useCellular: return "Use cellular this time"
            case .logIn: return "Log in to Telegram"
            case .openSettings: return "Open Settings"
            }
        }
    }

    var title: String
    /// A small line under the title, such as the file being uploaded.
    var detail: String?
    /// From 0 to 1 while uploading; `nil` hides the bar.
    var progress: Double?
    var action: Action?

    static func make(phase: AppModel.Phase, counts: StatusCounts) -> StatusSummary {
        switch phase {
        case .idle:
            let queued = queued(counts)
            return StatusSummary(title: queued == 0 ? "Up to date" : "\(items(queued)) to upload")
        case .syncing(let done, let total, let fileName, _):
            guard total > 0 else { return StatusSummary(title: "Checking for new photos…") }
            let current = min(total, max(1, fileName == nil ? done : done + 1))
            return StatusSummary(
                title: "Syncing \(current.formatted()) of \(total.formatted())",
                detail: fileName,
                progress: Double(min(done, total)) / Double(total))
        case .blocked(let reason):
            return blocked(reason, counts: counts)
        }
    }

    /// Units still to upload, including any interrupted mid-upload.
    static func queued(_ counts: StatusCounts) -> Int {
        counts.pending + counts.uploading
    }

    /// "Last synced 2 hours ago", or "Never synced".
    static func lastSynced(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never synced" }
        if now.timeIntervalSince(date) < 60 { return "Last synced just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last synced \(formatter.localizedString(for: date, relativeTo: now))"
    }

    private static func blocked(_ reason: BlockReason, counts: StatusCounts) -> StatusSummary {
        switch reason {
        case .noNetwork:
            return StatusSummary(title: "Waiting for internet")
        case .expensiveNetwork:
            return StatusSummary(title: "Waiting for Wi-Fi", action: .useCellular)
        case .needsCharger:
            let older = counts.backfillPending
            if older == 0 { return StatusSummary(title: "Older items will upload while charging") }
            let noun = older == 1 ? "item" : "items"
            return StatusSummary(title: "\(older.formatted()) older \(noun) will upload while charging")
        case .authLost:
            return StatusSummary(title: "Log in again", detail: "Telegram ended this app's session.", action: .logIn)
        case .noLibraryAccess:
            return StatusSummary(title: "Full Photos access needed", action: .openSettings)
        case .lowDisk:
            return StatusSummary(title: "Free up space on your iPhone")
        case .deadline, .cancelled:
            return make(phase: .idle, counts: counts)
        }
    }

    private static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }
}
