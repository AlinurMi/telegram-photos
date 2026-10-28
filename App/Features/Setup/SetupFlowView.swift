/// Shows one setup screen for the current Telegram login step.
import SwiftUI

/// An icon, a title and an optional line and button, centred.

/// Shown after login until the destination step arrives (T22). The test button is temporary.
struct SetupFlowView: View {
    @ObservedObject var telegram: TelegramService
    @State private var showPhoneInsteadOfQr = false

    var body: some View {
        content
            .animation(.smooth, value: telegram.step)
            .task { telegram.start() }
    }

    @ViewBuilder private var content: some View {
        switch telegram.step {
        case .starting:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background { SoftBackdrop() }
        case .needsCredentials:
            CredentialsView(telegram: telegram)
        case .waitingForPhone:
            phoneStep
        case .waitingForQr(let link):
            if showPhoneInsteadOfQr {
                phoneStep
            } else {
                QrLoginView(link: link, usePhone: { showPhoneInsteadOfQr = true })
            }
        case .waitingForCode:
            CodeStepView(telegram: telegram)
        case .waitingForPassword:
            PasswordStepView(telegram: telegram)
        case .ready:
            LoggedInView(telegram: telegram)
        case .unsupported:
            StatusMessage(
                symbol: "exclamationmark.triangle",
                title: "Can't log in here",
                message: "Telegram asked for a step this app doesn't support."
            )
        case .loggedOut:
            StatusMessage(
                symbol: "person.crop.circle.badge.xmark",
                title: "Logged out",
                buttonTitle: "Log in",
                action: { telegram.start() }
            )
        case .failed(let message):
            StatusMessage(symbol: "xmark.octagon", title: "Something went wrong", message: message)
        }
    }

    private var phoneStep: some View {
        PhoneStepView(telegram: telegram, useQr: useQr)
    }

    private func useQr() async throws {
        showPhoneInsteadOfQr = false
        if case .waitingForQr = telegram.step { return }
        try await telegram.requestQrLogin()
    }
}
private struct StatusMessage: View {
    let symbol: String
    let title: String
    var message: String?
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            if let message {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { SoftBackdrop() }
    }
}
private struct LoggedInView: View {
    let telegram: TelegramService

    @State private var status: String?
    @State private var failed = false
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.green)
            Text("You're logged in").font(.title2.bold())
            Button("Send test message", action: sendTest)
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(isSending)
                .padding(.top, 8)
            if let status {
                Text(status)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { SoftBackdrop() }
    }

    private func sendTest() {
        isSending = true
        status = nil
        Task {
            do {
                try await telegram.sendTestMessage()
                failed = false
                status = "Sent to Saved Messages."
            } catch let error as TelegramError {
                failed = true
                status = error.message
            } catch {
                failed = true
                status = "Couldn't send the message."
            }
            isSending = false
        }
    }
}
