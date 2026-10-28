import SwiftUI

/// One text field, one main button and a few quiet actions. The phone, code and password steps all use it.
struct LoginFieldStep: View {
    let title: String
    var subtitle: String?
    let placeholder: String
    let buttonTitle: String
    var isSecure = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var resend: ResendOption?
    var extras: [ExtraAction] = []
    let isValid: (String) -> Bool
    let submit: (String) async throws -> Void

    @State private var text = ""
    @State private var errorText: String?
    @State private var isWorking = false
    @FocusState private var focused: Bool

    var body: some View {
        ScreenLayout(title: title, subtitle: subtitle) {
            VStack(spacing: 16) {
                GlassField { field }
                if let errorText { ErrorLine(text: errorText) }
                PrimaryButton(title: buttonTitle, isWorking: isWorking, action: run)
                    .disabled(!isValid(text))
                VStack(spacing: 4) {
                    if let resend {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = Int(resend.availableAt.timeIntervalSince(context.date).rounded(.up))
                            QuietButton(
                                title: remaining > 0 ? "Resend code in \(remaining)s" : "Resend code",
                                action: { perform(resend.action) }
                            )
                            .disabled(isWorking || remaining > 0)
                        }
                    }
                    ForEach(extras) { extra in
                        QuietButton(title: extra.title, action: { perform(extra.action) })
                            .disabled(isWorking)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private var field: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .focused($focused)
        .keyboardType(keyboard)
        .textContentType(contentType)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(run)
    }

    private func run() {
        let value = isSecure ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking, isValid(value) else { return }
        perform { try await submit(value) }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorText = nil
        Task {
            do {
                try await work()
            } catch let error as TelegramError {
                errorText = error.message
            } catch {
                errorText = "Something went wrong. Try again."
            }
            isWorking = false
        }
    }
}

/// A quiet extra action under the main button, such as "Use different API details".
struct ExtraAction: Identifiable {
    let title: String
    let action: () async throws -> Void
    var id: String { title }
}

/// A "Resend code" action that unlocks at `availableAt`.
struct ResendOption {
    let availableAt: Date
    let action: () async throws -> Void
}

struct PhoneStepView: View {
    let telegram: TelegramService
    let useQr: () async throws -> Void

    var body: some View {
        LoginFieldStep(
            title: "Your number",
            subtitle: "Include the country code.",
            placeholder: "+1 555 123 4567",
            buttonTitle: "Send code",
            keyboard: .phonePad,
            contentType: .telephoneNumber,
            extras: [
                ExtraAction(title: "Log in with QR code", action: useQr),
                ExtraAction(
                    title: "Use different API details", action: { try await telegram.useDifferentCredentials() }),
            ],
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
            subtitle: telegram.codeDelivery?.method.explanation,
            placeholder: "Code",
            buttonTitle: "Continue",
            keyboard: .numberPad,
            contentType: .oneTimeCode,
            resend: resendOption,
            extras: [
                ExtraAction(
                    title: "Use different API details", action: { try await telegram.useDifferentCredentials() })
            ],
            isValid: { (5...6).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } },
            submit: { try await telegram.submitCode($0) }
        )
    }

    private var resendOption: ResendOption? {
        guard let delivery = telegram.codeDelivery, delivery.canResend else { return nil }
        return ResendOption(availableAt: delivery.resendAfter) { try await telegram.resendCode() }
    }
}

struct PasswordStepView: View {
    let telegram: TelegramService

    var body: some View {
        LoginFieldStep(
            title: "Password",
            subtitle: "Two-step verification.",
            placeholder: "Password",
            buttonTitle: "Continue",
            isSecure: true,
            contentType: .password,
            isValid: { !$0.isEmpty },
            submit: { try await telegram.submitPassword($0) }
        )
    }
}
