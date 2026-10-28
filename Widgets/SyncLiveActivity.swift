import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

extension Color {
    /// The app's `AccentColor`, repeated here because the extension has no asset catalog.
    fileprivate static let syncAccent = Color(
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.180, green: 0.525, blue: 0.918, alpha: 1)
                : UIColor(red: 0.106, green: 0.435, blue: 0.769, alpha: 1)
        })
}

/// A progress ring while syncing, a tick once finished.
private struct ProgressBadge: View {
    let state: SyncActivityAttributes.ContentState

    var body: some View {
        if state.finished {
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
                .foregroundStyle(Color.syncAccent)
        } else {
            ProgressView(value: state.fraction)
                .progressViewStyle(.circular)
                .tint(.syncAccent)
        }
    }
}

/// Current file, progress bar and counts, for the expanded island and the Lock Screen.
private struct ActivityDetails: View {
    let state: SyncActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = state.currentFileName, !state.finished {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ProgressView(value: state.fraction)
                .progressViewStyle(.linear)
                .tint(.syncAccent)
            Text(state.summary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

struct SyncLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            ActivityDetails(state: context.state)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityDetails(state: context.state)
                }
            } compactLeading: {
                ProgressBadge(state: context.state)
            } compactTrailing: {
                Text(context.state.compactText)
                    .monospacedDigit()
            } minimal: {
                ProgressBadge(state: context.state)
            }
            .keylineTint(.syncAccent)
        }
    }
}
