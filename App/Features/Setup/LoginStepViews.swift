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
            isValid: { $0.contains(where: \.isNumber) },
            submit: { try await telegram.submitPhone($0) }
        )
    }
}
struct CodeStepView: View {
    let telegram: TelegramService

    var body: some View {
        LoginFieldStep(
            title: "Enter the code",
            message: "Telegram sent a code to your Telegram app. Type it here.",
            placeholder: "Code",
            buttonTitle: "Continue",
            keyboard: .numberPad,
            contentType: .oneTimeCode,
            isValid: { (5...6).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } },
            submit: { try await telegram.submitCode($0) }
        )
    }
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
