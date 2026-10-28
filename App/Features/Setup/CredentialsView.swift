import SwiftUI

/// Asks for the Telegram API ID and hash, saves them to the Keychain and starts TDLib.
struct CredentialsView: View {
    let telegram: TelegramService

    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var errorText: String?

    private static let helpURL = URL(string: "https://my.telegram.org") ?? URL(fileURLWithPath: "/")

    private var canContinue: Bool {
        CredentialsValidator.apiId(apiId) != nil && CredentialsValidator.isValidApiHash(apiHash)
    }

    var body: some View {
        ScreenLayout(title: "Connect Telegram", subtitle: "Your own API details.") {
            VStack(spacing: 16) {
                GlassField {
                    TextField("API ID", text: $apiId)
                        .keyboardType(.numberPad)
                }
                GlassField {
                    TextField("API hash", text: $apiHash)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())
                }
                if let errorText { ErrorLine(text: errorText) }
                PrimaryButton(title: "Continue", action: save)
                    .disabled(!canContinue)
                Link("Where do I find these?", destination: Self.helpURL)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func save() {
        guard let id = CredentialsValidator.apiId(apiId), CredentialsValidator.isValidApiHash(apiHash) else {
            errorText = "Check the API ID and hash."
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
            errorText = "Couldn't save the details. Try again."
        }
    }
}
