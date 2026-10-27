import Foundation

import Security

import SyncCore

/// Where the Telegram login stands. The setup screens show one view per case.
import TDLibKit

/// Owns the one TDLib client of the process and publishes the login state.
///
/// Create it once (`TelegramService.shared`). Nothing starts until `start()` is called.
/// Only auth state names are logged. Never log the phone number, the code or the password.
enum AuthStep: Equatable, Sendable {
    /// TDLib is starting and hasn't reported its state yet.
    case starting
    /// No API ID / API hash in the Keychain yet.
    case needsCredentials
    case waitingForPhone
    case waitingForCode
    case waitingForPassword
    case ready
    /// Telegram asked for a step this app can't do (e.g. email login). `name` is the TDLib state name.
    case unsupported(String)
    case loggedOut
    /// TDLib could not be started. `message` is plain text for the owner.
    case failed(String)

    /// Maps a TDLib authorization state name (e.g. `authorizationStateWaitCode`) to a step.
    static func step(forStateName name: String) -> AuthStep {
        switch name {
        case "authorizationStateWaitTdlibParameters":
            return .starting
        case "authorizationStateWaitPhoneNumber":
            return .waitingForPhone
        case "authorizationStateWaitCode":
            return .waitingForCode
        case "authorizationStateWaitPassword":
            return .waitingForPassword
        case "authorizationStateReady":
            return .ready
        case "authorizationStateLoggingOut", "authorizationStateClosing", "authorizationStateClosed":
            return .loggedOut
        default:
            return .unsupported(name)
        }
    }
}
extension AuthorizationState {
    /// The state's case name only. Never `String(describing:)`, because payloads can hold the phone number.
    fileprivate var stateName: String {
        switch self {
        case .authorizationStateWaitTdlibParameters: return "authorizationStateWaitTdlibParameters"
        case .authorizationStateWaitPhoneNumber: return "authorizationStateWaitPhoneNumber"
        case .authorizationStateWaitPremiumPurchase: return "authorizationStateWaitPremiumPurchase"
        case .authorizationStateWaitEmailAddress: return "authorizationStateWaitEmailAddress"
        case .authorizationStateWaitEmailCode: return "authorizationStateWaitEmailCode"
        case .authorizationStateWaitCode: return "authorizationStateWaitCode"
        case .authorizationStateWaitOtherDeviceConfirmation: return "authorizationStateWaitOtherDeviceConfirmation"
        case .authorizationStateWaitRegistration: return "authorizationStateWaitRegistration"
        case .authorizationStateWaitPassword: return "authorizationStateWaitPassword"
        case .authorizationStateReady: return "authorizationStateReady"
        case .authorizationStateLoggingOut: return "authorizationStateLoggingOut"
        case .authorizationStateClosing: return "authorizationStateClosing"
        case .authorizationStateClosed: return "authorizationStateClosed"
        }
    }
}
@MainActor
final class TelegramService: ObservableObject {
    static let shared = TelegramService()

    @Published private(set) var step: AuthStep = .starting

    private struct Credentials {
        let apiId: Int
        let apiHash: String
    }

    private let keychain: KeychainStore
    private let logger: FileLogger
    private let rootDirectory: URL?
    private var manager: TDLibClientManager?
    private var client: TDLibClient?
    private var updates: AsyncStream<AuthorizationState>.Continuation?
    private var updatesTask: Task<Void, Never>?

    /// - Parameters:
    ///   - keychain: Holds the API credentials and the database key.
    ///   - rootDirectory: Parent of the `tdlib` folder. Defaults to `Application Support`.
    init(keychain: KeychainStore = .shared, logger: FileLogger = log, rootDirectory: URL? = nil) {
        self.keychain = keychain
        self.logger = logger
        self.rootDirectory = rootDirectory
    }

    /// Starts TDLib if it isn't running. Safe to call again, for example after saving API credentials.
    func start() {
        guard client == nil else { return }
        do {
            guard try loadCredentials() != nil else {
                publish(.needsCredentials)
                return
            }
        } catch {
            logger.error("Could not read API credentials: \(error)", category: "telegram")
            publish(.failed("Couldn't read your saved Telegram details."))
            return
        }

        publish(.starting)
        let (stream, continuation) = AsyncStream.makeStream(of: AuthorizationState.self)
        let manager = self.manager ?? TDLibClientManager()
        self.manager = manager
        // Updates come in on TDLib's queue; the stream keeps their order on the way to the main actor.
        client = manager.createClient { data, client in
            guard
                let update = try? client.decoder.decode(Update.self, from: data),
                case .updateAuthorizationState(let change) = update
            else { return }
            continuation.yield(change.authorizationState)
        }
        updates = continuation
        updatesTask = Task { [weak self] in
            for await state in stream {
                await self?.handle(state)
            }
        }
    }

    /// Sends the phone number; Telegram then sends a code.
    func submitPhone(_ phone: String) async throws {
        try await perform { _ = try await $0.setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil) }
    }

    /// Checks the login code.
    func submitCode(_ code: String) async throws {
        try await perform { _ = try await $0.checkAuthenticationCode(code: code) }
    }

    /// Checks the two-step verification password.
    func submitPassword(_ password: String) async throws {
        try await perform { _ = try await $0.checkAuthenticationPassword(password: password) }
    }

    /// Logs out of Telegram and deletes TDLib's local data.
    func logOut() async throws {
        guard client != nil else {
            publish(.loggedOut)
            return
        }
        try await perform { _ = try await $0.logOut() }
    }

    /// Returns once TDLib is logged in. Used by background runs.
    ///
    /// Waits up to `timeout` seconds while TDLib is still starting. Any state that needs the owner
    /// throws `UploadError(.authLost)`. A start that takes too long throws a transient error.
    func waitUntilReady(timeout: TimeInterval) async throws {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch step {
            case .ready:
                return
            case .starting:
                guard Date() < deadline else {
                    throw UploadError(kind: .transient, message: "telegramNotReady")
                }
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    throw UploadError(kind: .cancelled, message: "cancelled")
                }
            default:
                throw UploadError(kind: .authLost, message: "notLoggedIn")
            }
        }
    }

    private func handle(_ state: AuthorizationState) async {
        let name = state.stateName
        logger.info("Auth state: \(name)", category: "telegram")
        switch state {
        case .authorizationStateWaitTdlibParameters:
            await sendParameters()
        case .authorizationStateClosed:
            updates?.finish()
            updates = nil
            updatesTask = nil
            client = nil
            publish(.loggedOut)
        default:
            publish(AuthStep.step(forStateName: name))
        }
    }

    private func sendParameters() async {
        guard let client else { return }
        do {
            guard let credentials = try loadCredentials() else {
                publish(.needsCredentials)
                return
            }
            let key = try databaseKey()
            let root = rootDirectory
            let directories = try await Task.detached(priority: .utility) {
                try Self.prepareDirectories(root: root)
            }.value
            _ = try await client.setTdlibParameters(
                apiHash: credentials.apiHash,
                apiId: credentials.apiId,
                applicationVersion: Self.appVersion,
                databaseDirectory: directories.database.path,
                databaseEncryptionKey: key,
                deviceModel: "iPhone",
                filesDirectory: directories.files.path,
                systemLanguageCode: "en",
                systemVersion: nil,
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: false,
                useSecretChats: false,
                useTestDc: false
            )
        } catch let error as TDLibKit.Error {
            logger.error("setTdlibParameters failed: \(error.code) \(error.message)", category: "telegram")
            publish(.failed(TDLibErrorMapping.readableMessage(code: error.code, message: error.message)))
        } catch {
            logger.error("Could not start Telegram: \(error)", category: "telegram")
            publish(.failed("Couldn't start Telegram."))
        }
    }

    private func perform(_ operation: (TDLibClient) async throws -> Void) async throws {
        guard let client else {
            throw TelegramError(message: "Telegram isn't running. Close and reopen the app.")
        }
        do {
            try await operation(client)
        } catch let error as TDLibKit.Error {
            logger.warning("Telegram request failed: \(error.code) \(error.message)", category: "telegram")
            throw TelegramError(
                message: TDLibErrorMapping.readableMessage(code: error.code, message: error.message)
            )
        }
    }

    private func publish(_ newStep: AuthStep) {
        guard newStep != step else { return }
        step = newStep
    }

    private func loadCredentials() throws -> Credentials? {
        guard
            let idText = try keychain.string(for: KeychainStore.Key.apiId),
            let apiId = Int(idText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let hash = try keychain.string(for: KeychainStore.Key.apiHash)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !hash.isEmpty
        else { return nil }
        return Credentials(apiId: apiId, apiHash: hash)
    }

    /// The database key from the Keychain; 32 random bytes are created on first use.
    private func databaseKey() throws -> Data {
        if let existing = try keychain.data(for: KeychainStore.Key.dbKey) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let key = Data(bytes)
        try keychain.set(key, for: KeychainStore.Key.dbKey)
        return key
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.isEmpty ? "0.1.0" : version
    }

    /// Creates `tdlib/db` and `tdlib/files` with file protection that allows background access after first unlock.
    private nonisolated static func prepareDirectories(root: URL?) throws -> (database: URL, files: URL) {
        let fileManager = FileManager.default
        let base =
            try root
            ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        let tdlib = base.appendingPathComponent("tdlib", isDirectory: true)
        let database = tdlib.appendingPathComponent("db", isDirectory: true)
        let files = tdlib.appendingPathComponent("files", isDirectory: true)
        for directory in [tdlib, database, files] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
        }
        return (database, files)
    }
}
