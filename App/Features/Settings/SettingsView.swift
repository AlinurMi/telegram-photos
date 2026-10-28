import SwiftUI

/// The settings screen. For now it shows the version and the debug screen; the options are added later.
struct SettingsView: View {
    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
            Section {
                DisclosureGroup("Advanced") {
                    NavigationLink("Debug screen") { SpikeView() }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
