/// One text field, one button and an inline error. The phone, code and password steps all use it.
import SwiftUI

struct LoginFieldStep: View {
    let title: String
    let message: String
    let placeholder: String
    let buttonTitle: String
    var isSecure = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var resend: ResendOption?
    var changeCredentials: (() async throws -> Void)?
    let isValid: (String) -> Bool
    let submit: (String) async throws -> Void

    @State private var text = ""
    @State private var errorText: String?
    @State private var isWorking = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                Text(message)
            }
            Section {
                field
                    .focused($focused)
                    .keyboardType(keyboard)
                    .textContentType(contentType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(run)
            }
            if let errorText {
                Section {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            Section {
                Button(action: run) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text(buttonTitle)
                    }
                }
                .disabled(isWorking || !isValid(text))
            }
            if let resend {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = Int(resend.availableAt.timeIntervalSince(context.date).rounded(.up))
                        Button(remaining > 0 ? "Resend code in \(remaining)s" : "Resend code", action: runResend)
                            .disabled(isWorking || remaining > 0)
                    }
                }
            }
            if let changeCredentials {
                Section {
                    Button("Use different API details") { runChangeCredentials(changeCredentials) }
                        .disabled(isWorking)
                }
            }
        }
        .navigationTitle(title)
        .onAppear { focused = true }
    }

    @ViewBuilder private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    private func runChangeCredentials(_ change: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorText = nil
        Task {
            do {
                try await change()
            } catch let error as TelegramError {
                errorText = error.message
            } catch {
                errorText = "Couldn't clear the saved details. Try again."
            }
            isWorking = false
        }
    }

    private func runResend() {
        guard let resend, !isWorking else { return }
        isWorking = true
        errorText = nil
        Task {
            do {
                try await resend.action()
            } catch let error as TelegramError {
                errorText = error.message
            } catch {
                errorText = "Something went wrong. Try again."
            }
            isWorking = false
        }
    }

    private func run() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking, isValid(value) else { return }
        isWorking = true
        errorText = nil
        Task {
            do {
                try await submit(value)
            } catch let error as TelegramError {
                errorText = error.message
            } catch {
                errorText = "Something went wrong. Try again."
            }
            isWorking = false
        }
    }
}
struct PhoneStepView: View {
    let telegram: TelegramService

    var body: some View {
        LoginFieldStep(
            title: "Your phone",
            message:
                "Enter your phone number with the country code, like +1 555 123 4567. Telegram will send you a code.",
            placeholder: "+1 555 123 4567",
            buttonTitle: "Send code",
            keyboard: .phonePad,
            contentType: .telephoneNumber,
            changeCredentials: { try await telegram.useDifferentCredentials() },
            isValid: { $0.contains(where: \.isNumber) },
            submit: { try await telegram.submitPhone($0) }
        )
    }
}
struct CodeStepView: View {
    @ObservedObject var telegram: TelegramService

    var body: some View {
        LoginFieldStep(
            title: "Enter the code",
            message: telegram.codeDelivery?.method.explanation ?? "Telegram sent you a login code. Type it here.",
            placeholder: "Code",
            buttonTitle: "Continue",
            keyboard: .numberPad,
            contentType: .oneTimeCode,
            resend: resendOption,
            changeCredentials: { try await telegram.useDifferentCredentials() },
            isValid: { (5...6).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } },
            submit: { try await telegram.submitCode($0) }
        )
    }

    private var resendOption: ResendOption? {
        guard let delivery = telegram.codeDelivery, delivery.canResend else { return nil }
        return ResendOption(availableAt: delivery.resendAfter) { try await telegram.resendCode() }
    }
}

/// A "Resend code" button that unlocks at `availableAt`.
struct ResendOption {
    let availableAt: Date
    let action: () async throws -> Void
}
struct PasswordStepView: View {
    let telegram: TelegramService

    var body: some View {
        LoginFieldStep(
            title: "Password",
            message: "Your account has two-step verification. Enter your Telegram password.",
            placeholder: "Password",
            buttonTitle: "Continue",
            isSecure: true,
            contentType: .password,
            isValid: { !$0.isEmpty },
            submit: { try await telegram.submitPassword($0) }
        )
    }
}
