import SwiftUI
import SyncCore

/// Shows one setup screen for the current Telegram login step, then the steps after login.
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
            AfterLoginFlow(telegram: telegram)
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

/// Destination, Photos, notifications, then setup is marked as done and the main screen takes over.
///
/// The current step is worked out from what's already saved, so it's checked again whenever the app
/// comes back to the foreground (for example after Settings).
private struct AfterLoginFlow: View {
    let telegram: TelegramService

    @Environment(\.scenePhase) private var scenePhase
    @State private var stage: SetupStage?
    @State private var notificationsAnswered = false
    @State private var isFinishing = false
    @State private var finishFailed = false

    var body: some View {
        content
            .animation(.smooth, value: stage)
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refresh() }
            }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .destination?:
            DestinationView(telegram: telegram, onChosen: { Task { await refresh() } })
        case .photos(let access)?:
            PhotosPermissionView(access: access, onChange: { Task { await refresh() } })
        case .notifications?:
            NotificationsPermissionView(onDone: {
                notificationsAnswered = true
                Task { await refresh() }
            })
        case nil, .finishing?:
            if finishFailed {
                StatusMessage(
                    symbol: "xmark.octagon",
                    title: "Couldn't finish setup",
                    buttonTitle: "Try again",
                    action: { Task { await refresh() } }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background { SoftBackdrop() }
            }
        }
    }

    private func refresh() async {
        let photos = await PhotoKitLibrary().authorization()
        var notificationsPending = false
        if !notificationsAnswered {
            notificationsPending = await NotificationsPermissionView.isUndecided()
        }
        let next = SetupStage.next(
            hasDestination: telegram.destinationChatId != nil,
            photos: photos,
            notificationsPending: notificationsPending
        )
        stage = next
        if next == .finishing { await finish() }
    }

    private func finish() async {
        guard !isFinishing else { return }
        isFinishing = true
        finishFailed = false
        do {
            // Sets `setupCompleted`, which swaps the setup flow for the main screen.
            try await SyncCoordinator.shared.finishSetup()
            log.info("Setup finished", category: "setup")
        } catch {
            log.error("Could not finish setup: \(type(of: error))", category: "setup")
            finishFailed = true
        }
        isFinishing = false
    }
}

/// An icon, a title and an optional line and button, centred.
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
