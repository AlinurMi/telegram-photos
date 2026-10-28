/// Shows one setup screen for the current Telegram login step.
import SwiftUI

/// Shown after login until the destination step arrives (T22). The test button is temporary.
struct SetupFlowView: View {
    @ObservedObject var telegram: TelegramService

    var body: some View {
        NavigationStack {
            content
        }
        .task { telegram.start() }
    }

    @ViewBuilder private var content: some View {
        switch telegram.step {
        case .starting:
            ProgressView("Starting…")
        case .needsCredentials:
            CredentialsView(telegram: telegram)
        case .waitingForPhone:
            PhoneStepView(telegram: telegram)
        case .waitingForCode:
            CodeStepView(telegram: telegram)
        case .waitingForPassword:
            PasswordStepView(telegram: telegram)
        case .ready:
            LoggedInView(telegram: telegram)
        case .unsupported:
            MessageView(
                title: "Can't log in here",
                message:
                    "Telegram asked for a step this app doesn't support (for example email login). Log in to Telegram on another device first, then try again."
            )
        case .loggedOut:
            MessageView(
                title: "Logged out",
                message: "You're not logged in to Telegram.",
                buttonTitle: "Log in",
                action: { telegram.start() }
            )
        case .failed(let message):
            MessageView(title: "Something went wrong", message: "\(message) Close and reopen the app to try again.")
        }
    }
}
private struct MessageView: View {
    let title: String
    let message: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
private struct LoggedInView: View {
    let telegram: TelegramService

    @State private var status: String?
    @State private var failed = false
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("You're logged in").font(.title2.bold())
            Button("Send test message", action: sendTest)
                .buttonStyle(.borderedProminent)
                .disabled(isSending)
            if let status {
                Text(status)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
            }
        }
        .padding()
    }

    private func sendTest() {
        isSending = true
        status = nil
        Task {
            do {
                try await telegram.sendTestMessage()
                failed = false
                status = "Sent. Check Saved Messages in Telegram."
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
