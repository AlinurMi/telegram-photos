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
    private let defaults: UserDefaults
    private let rootDirectory: URL?
    private let sendTracker = SendTracker()
    private var cachedMaxFileSize: Int64?
    private var manager: TDLibClientManager?
    private var client: TDLibClient?
    private var updates: AsyncStream<AuthorizationState>.Continuation?
    private var updatesTask: Task<Void, Never>?

    /// - Parameters:
    ///   - keychain: Holds the API credentials and the database key.
    ///   - defaults: Holds the destination chat. Nothing in there is secret.
    ///   - rootDirectory: Parent of the `tdlib` folder. Defaults to `Application Support`.
    init(
        keychain: KeychainStore = .shared,
        logger: FileLogger = log,
        defaults: UserDefaults = .standard,
        rootDirectory: URL? = nil
    ) {
        self.keychain = keychain
        self.logger = logger
        self.defaults = defaults
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
        // Send results and upload progress go straight to the tracker, which is safe to call from any thread.
        let tracker = sendTracker
        client = manager.createClient { data, client in
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            switch update {
            case .updateAuthorizationState(let change):
                continuation.yield(change.authorizationState)
            case .updateMessageSendSucceeded(let sent):
                tracker.record(.sent(messageId: sent.message.id), for: sent.oldMessageId)
            case .updateMessageSendFailed(let failed):
                let error = TDLibErrorMapping.uploadError(code: failed.error.code, message: failed.error.message)
                tracker.record(.failed(error), for: failed.oldMessageId)
            case .updateFile(let changed):
                tracker.fileUpdated(id: changed.file.id, uploadedSize: changed.file.remote.uploadedSize)
            default:
                break
            }
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
            cachedMaxFileSize = nil
            sendTracker.failPending(with: UploadError(kind: .authLost, message: "telegramClosed"))
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

    private func perform<T>(_ operation: (TDLibClient) async throws -> T) async throws -> T {
        guard let client else {
            throw TelegramError(message: "Telegram isn't running. Close and reopen the app.")
        }
        do {
            return try await operation(client)
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

/// A chat the backup can go to.
struct ChatSummary: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case channel
        case group
        case savedMessages
    }

    let id: Int64
    let title: String
    let kind: Kind
}

extension ChatMemberStatus {
    fileprivate var memberRole: ChatMemberRole {
        switch self {
        case .chatMemberStatusCreator:
            return .creator
        case .chatMemberStatusAdministrator(let administrator):
            return .administrator(canPostMessages: administrator.rights.canPostMessages)
        case .chatMemberStatusMember:
            return .member
        case .chatMemberStatusRestricted(let restricted):
            return .restricted(isMember: restricted.isMember, canSendDocuments: restricted.permissions.canSendDocuments)
        case .chatMemberStatusLeft:
            return .left
        case .chatMemberStatusBanned:
            return .banned
        }
    }
}

// MARK: - Chats and destination

extension TelegramService {
    nonisolated static let destinationChatIdKey = "destinationChatId"
    nonisolated static let destinationTitleKey = "destinationTitle"
    static let backupChannelTitle = "📷 iPhone Backup"
    private static let savedMessagesTitle = "Saved Messages"

    /// The chat the backup goes to, if one was chosen.
    var destinationChatId: Int64? {
        let value = defaults.integer(forKey: Self.destinationChatIdKey)
        return value == 0 ? nil : Int64(value)
    }

    var destinationTitle: String? {
        defaults.string(forKey: Self.destinationTitleKey)
    }

    func setDestination(_ chat: ChatSummary) {
        defaults.set(Int(chat.id), forKey: Self.destinationChatIdKey)
        defaults.set(chat.title, forKey: Self.destinationTitleKey)
    }

    func clearDestination() {
        defaults.removeObject(forKey: Self.destinationChatIdKey)
        defaults.removeObject(forKey: Self.destinationTitleKey)
    }

    /// Channels you can post in, groups you can send files to, and Saved Messages.
    func listWritableChats() async throws -> [ChatSummary] {
        try await perform { client in
            do {
                _ = try await client.loadChats(chatList: .chatListMain, limit: 200)
            } catch let error as TDLibKit.Error where error.code == 404 {
                // Every chat was already loaded.
            }
            let chatIds = try await client.getChats(chatList: .chatListMain, limit: 200).chatIds
            let myId = try await client.getMe().id
            var chats: [ChatSummary] = []
            for chatId in chatIds {
                do {
                    let chat = try await client.getChat(chatId: chatId)
                    if let summary = try await Self.writableSummary(of: chat, myId: myId, client: client) {
                        chats.append(summary)
                    }
                } catch {
                    logger.warning("Skipped a chat that could not be read: \(error)", category: "telegram")
                }
            }
            if !chats.contains(where: { $0.kind == .savedMessages }) {
                let chat = try await client.createPrivateChat(force: true, userId: myId)
                chats.append(ChatSummary(id: chat.id, title: Self.savedMessagesTitle, kind: .savedMessages))
            }
            return chats
        }
    }

    /// Creates a private channel for the backup. It does not become the destination until `setDestination`.
    func createBackupChannel() async throws -> ChatSummary {
        try await perform { client in
            let chat = try await client.createNewSupergroupChat(
                description: "Backups from TelegramPhotos",
                forImport: false,
                isChannel: true,
                isForum: false,
                location: nil,
                messageAutoDeleteTime: 0,
                title: Self.backupChannelTitle
            )
            return ChatSummary(id: chat.id, title: chat.title, kind: .channel)
        }
    }

    func savedMessagesChat() async throws -> ChatSummary {
        try await perform { client in
            let me = try await client.getMe()
            let chat = try await client.createPrivateChat(force: true, userId: me.id)
            return ChatSummary(id: chat.id, title: Self.savedMessagesTitle, kind: .savedMessages)
        }
    }

    private static func writableSummary(of chat: Chat, myId: Int64, client: TDLibClient) async throws
        -> ChatSummary?
    {
        let membersCanSendDocuments = chat.permissions.canSendDocuments
        switch chat.type {
        case .chatTypePrivate(let privateChat):
            guard privateChat.userId == myId else { return nil }
            return ChatSummary(id: chat.id, title: savedMessagesTitle, kind: .savedMessages)
        case .chatTypeBasicGroup(let basicGroup):
            let group = try await client.getBasicGroup(basicGroupId: basicGroup.basicGroupId)
            guard
                ChatWriteAccess.canSend(
                    isChannel: false, role: group.status.memberRole, membersCanSendDocuments: membersCanSendDocuments)
            else { return nil }
            return ChatSummary(id: chat.id, title: chat.title, kind: .group)
        case .chatTypeSupergroup(let supergroup):
            let group = try await client.getSupergroup(supergroupId: supergroup.supergroupId)
            guard
                ChatWriteAccess.canSend(
                    isChannel: supergroup.isChannel, role: group.status.memberRole,
                    membersCanSendDocuments: membersCanSendDocuments)
            else { return nil }
            return ChatSummary(id: chat.id, title: chat.title, kind: supergroup.isChannel ? .channel : .group)
        case .chatTypeSecret:
            return nil
        }
    }
}

// MARK: - Sending and searching

extension TelegramService: TelegramUploader {
    private static let mebibyte: Int64 = 1024 * 1024

    /// 4000 MiB with Telegram Premium, otherwise 2000 MiB. Looked up once per launch.
    func maxFileSize() async -> Int64 {
        if let cachedMaxFileSize { return cachedMaxFileSize }
        let standard = 2000 * Self.mebibyte
        guard let client else { return standard }
        do {
            let size = try await client.getMe().isPremium ? 4000 * Self.mebibyte : standard
            cachedMaxFileSize = size
            return size
        } catch {
            logger.warning("Could not read the account type: \(error)", category: "telegram")
            return standard
        }
    }

    func sendDocument(
        fileURL: URL,
        caption: Caption,
        progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void
    ) async throws -> Int64 {
        try await uploadCall {
            try Task.checkCancellation()
            let client = try readyClient()
            let chatId = try requireDestination()
            let formatted = await formattedText(for: caption, client: client)
            let content = InputMessageContent.inputMessageDocument(
                InputMessageDocument(
                    caption: formatted,
                    document: InputDocument(
                        disableContentTypeDetection: true,
                        document: .inputFileLocal(InputFileLocal(path: fileURL.path)),
                        thumbnail: nil
                    )
                )
            )
            let message = try await client.sendMessage(
                chatId: chatId,
                inputMessageContent: content,
                options: nil,
                replyMarkup: nil,
                replyTo: nil,
                topicId: nil
            )

            let tracker = sendTracker
            var watchedFileId: Int?
            if case .messageDocument(let document) = message.content {
                let file = document.document.document
                let size = Self.fileSize(at: fileURL)
                tracker.watchFile(id: file.id, total: size > 0 ? size : file.expectedSize, onProgress: progress)
                watchedFileId = file.id
            }
            defer {
                if let id = watchedFileId { tracker.unwatchFile(id: id) }
            }

            // The message returned above is temporary; the real id arrives with the send result.
            let temporaryId = message.id
            let outcome = await withTaskCancellationHandler {
                await tracker.outcome(for: temporaryId)
            } onCancel: {
                // Deleting a message that is still uploading stops the upload.
                if tracker.abandon(temporaryId) {
                    Task {
                        _ = try? await client.deleteMessages(chatId: chatId, messageIds: [temporaryId], revoke: true)
                    }
                }
            }
            switch outcome {
            case .sent(let messageId):
                return messageId
            case .failed(let error):
                throw error
            }
        }
    }

    func findMessage(assetTag: String, role: UnitRole) async throws -> Int64? {
        try await uploadCall {
            let client = try readyClient()
            let chatId = try requireDestination()
            let found = try await client.searchChatMessages(
                chatId: chatId,
                filter: .searchMessagesFilterDocument,
                fromMessageId: 0,
                limit: 20,
                offset: 0,
                query: "#\(assetTag)",
                senderId: nil,
                topicId: nil
            )
            for message in found.messages {
                guard
                    case .messageDocument(let document) = message.content,
                    let parsed = ChannelIndexParser.parse(caption: document.caption.text),
                    parsed.assetTag == assetTag,
                    parsed.role == role
                else { continue }
                return message.id
            }
            return nil
        }
    }

    nonisolated func allDocumentCaptions() -> AsyncThrowingStream<String, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var fromMessageId: Int64 = 0
                    while true {
                        let page = try await self.documentCaptionsPage(from: fromMessageId)
                        for caption in page.captions { continuation.yield(caption) }
                        guard !page.captions.isEmpty, page.next != 0, page.next != fromMessageId else { break }
                        fromMessageId = page.next
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func documentCaptionsPage(from fromMessageId: Int64) async throws -> (captions: [String], next: Int64) {
        try await uploadCall {
            try Task.checkCancellation()
            let client = try readyClient()
            let chatId = try requireDestination()
            let found = try await client.searchChatMessages(
                chatId: chatId,
                filter: .searchMessagesFilterDocument,
                fromMessageId: fromMessageId,
                limit: 100,
                offset: 0,
                query: "",
                senderId: nil,
                topicId: nil
            )
            let captions = found.messages.compactMap { message -> String? in
                guard case .messageDocument(let document) = message.content else { return nil }
                return document.caption.text
            }
            return (captions, found.nextFromMessageId)
        }
    }

    /// TDLib finds the hashtags; the caption's own links are added on top.
    /// Only hashtags are kept, because file names like `IMG_1.MOV` can look like web addresses.
    private func formattedText(for caption: Caption, client: TDLibClient) async -> FormattedText {
        var entities: [TextEntity] = []
        do {
            let detected = try await client.getTextEntities(text: caption.text)
            entities = detected.entities.filter {
                if case .textEntityTypeHashtag = $0.type { return true }
                return false
            }
        } catch {
            logger.warning("Could not find hashtags in a caption: \(error)", category: "telegram")
        }
        for link in caption.links {
            entities.append(
                TextEntity(
                    length: link.utf16Length,
                    offset: link.utf16Offset,
                    type: .textEntityTypeTextUrl(TextEntityTypeTextUrl(url: link.url))
                )
            )
        }
        return FormattedText(entities: entities.sorted { $0.offset < $1.offset }, text: caption.text)
    }

    private func readyClient() throws -> TDLibClient {
        switch step {
        case .ready:
            guard let client else { throw UploadError(kind: .authLost, message: "notLoggedIn") }
            return client
        case .starting:
            throw UploadError(kind: .transient, message: "telegramNotReady")
        default:
            throw UploadError(kind: .authLost, message: "notLoggedIn")
        }
    }

    private func requireDestination() throws -> Int64 {
        guard let chatId = destinationChatId else {
            throw UploadError(kind: .transient, message: "noDestination")
        }
        return chatId
    }

    /// Runs a Telegram call and turns every failure into an `UploadError` the engine can act on.
    private func uploadCall<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as UploadError {
            throw error
        } catch let error as TDLibKit.Error {
            logger.warning("Telegram call failed: \(error.code) \(error.message)", category: "telegram")
            throw TDLibErrorMapping.uploadError(code: error.code, message: error.message)
        } catch is CancellationError {
            throw UploadError(kind: .cancelled, message: "cancelled")
        } catch {
            logger.warning("Telegram call failed: \(error)", category: "telegram")
            throw UploadError(kind: .transient, message: "unexpectedError")
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
