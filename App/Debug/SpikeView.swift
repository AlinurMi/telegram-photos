import SwiftUI

/// Temporary screen for the phone checks; removed in the final polish task.
struct SpikeView: View {
    @State private var model = SpikeModel.shared

    var body: some View {
        List {
            Section("Demos") {
                Button("Demo Live Activity") { model.startLiveActivityDemo() }
            }
            Section("Status") {
                row("Live Activity", model.liveActivityStatus)
            }
            Section("Install info") {
                row("App bundle ID", Bundle.main.bundleIdentifier ?? "Unknown")
                row("Widget bundle ID", SpikeIdentifiers.widgetBundleID ?? "Not found")
                ForEach(BackgroundSync.permittedIdentifiers, id: \.self) { identifier in
                    row("Permitted task ID", identifier)
                }
            }
        }
        .navigationTitle("Debug")
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }
}
