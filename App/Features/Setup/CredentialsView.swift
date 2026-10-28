/// Asks for the Telegram API ID and hash, saves them to the Keychain and starts TDLib.
import SwiftUI

struct CredentialsView: View {
    let telegram: TelegramService

    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var errorText: String?

    private var canContinue: Bool {
        CredentialsValidator.apiId(apiId) != nil && CredentialsValidator.isValidApiHash(apiHash)
    }

    var body: some View {
        Form {
            Section {
                Text("TelegramPhotos needs your own Telegram API details to log in.")
                Link("Where do I get these?", destination: Self.helpURL)
            }
            Section("API ID") {
                TextField("Numbers only", text: $apiId)
                    .keyboardType(.numberPad)
            }
            Section("API hash") {
                TextField("32 letters and numbers", text: $apiHash)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }
            if let errorText {
                Section {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            Section {
                Button("Continue", action: save)
                    .disabled(!canContinue)
            }
        }
        .navigationTitle("Welcome")
    }

    private static let helpURL = URL(string: "https://my.telegram.org") ?? URL(fileURLWithPath: "/")

    private func save() {
        guard let id = CredentialsValidator.apiId(apiId), CredentialsValidator.isValidApiHash(apiHash) else {
            errorText = "Check the API ID (numbers only) and the API hash (32 characters)."
            return
        }
        do {
            let hash = apiHash.trimmingCharacters(in: .whitespacesAndNewlines)
            try KeychainStore.shared.setString(String(id), for: KeychainStore.Key.apiId)
            try KeychainStore.shared.setString(hash, for: KeychainStore.Key.apiHash)
            errorText = nil
            telegram.start()
        } catch {
            log.error("Could not save API credentials: \(error)", category: "setup")
            errorText = "Couldn't save the details on this iPhone. Try again."
        }
    }
}
