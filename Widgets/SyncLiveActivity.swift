import ActivityKit

import SwiftUI

import WidgetKit

private extension SyncActivityAttributes.ContentState {
    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    var summary: String {
        if finished {
            return "\(done) uploaded · \(Self.format(uploadedBytes))"
        }
        return "\(done)/\(total) · \(Self.format(bytesRemaining)) left"
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
private struct ProgressBadge: View {
    let state: SyncActivityAttributes.ContentState

    var body: some View {
        if state.finished {
            Image(systemName: "checkmark")
        } else {
            ProgressView(value: state.fraction)
                .progressViewStyle(.circular)
        }
    }
}
private struct ActivityDetails: View {
    let state: SyncActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = state.currentFileName, !state.finished {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            ProgressView(value: state.finished ? 1 : state.fraction)
                .progressViewStyle(.linear)
            Text(state.summary)
                .font(.caption)
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
                Text(context.state.finished ? "\(context.state.done)" : "\(context.state.done)/\(context.state.total)")
            } minimal: {
                ProgressBadge(state: context.state)
            }
        }
    }
}
