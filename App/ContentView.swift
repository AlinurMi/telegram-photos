import SwiftUI
import SyncCore

struct ContentView: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text("TelegramPhotos \(appVersion)")
                    .font(.title2)
                Text("SyncCore \(SyncCoreInfo.version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("Debug screen") { SpikeView() }
                    .padding(.top, 16)
            }
            .padding()
        }
    }
}
