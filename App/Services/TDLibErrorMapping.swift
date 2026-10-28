import Foundation
import SyncCore

/// A Telegram request failed. `message` is short, plain and safe to show to the owner.
struct TelegramError: Error, LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

/// Turns TDLib error codes into plain messages for the owner.
///
/// Takes the raw code and text so it stays free of TDLibKit types.
enum TDLibErrorMapping {
    private static let knownMessages: [(needle: String, text: String)] = [
        ("PHONE_CODE_INVALID", "Wrong code"),
        ("PHONE_CODE_EXPIRED", "That code has expired. Start again to get a new one."),
        ("PHONE_NUMBER_INVALID", "That phone number doesn't look right. Include the country code."),
        ("PASSWORD_HASH_INVALID", "Wrong password"),
        ("API_ID_INVALID", "Telegram rejected the API ID or API hash. Check them and try again."),
        ("FLOOD", "Too many attempts. Wait a few minutes and try again."),
    ]

    static func readableMessage(code: Int, message: String) -> String {
        let text = message.uppercased()
        if let known = knownMessages.first(where: { text.contains($0.needle) }) {
            return known.text
        }
        switch code {
        case 429:
            return "Too many attempts. Wait a few minutes and try again."
        case 401:
            return "Telegram needs you to log in again."
        case 500:
            return "Telegram isn't available right now. Try again in a moment."
        default:
            return "Telegram error: \(message)"
        }
    }

    /// Sorts a failed send or search into the category that decides how the engine retries it.
    static func uploadError(code: Int, message: String) -> UploadError {
        let text = message.uppercased()
        let description = "telegram \(code): \(message)"
        if code == 429 || text.contains("TOO MANY REQUESTS") || text.contains("FLOOD_WAIT") {
            return UploadError(
                kind: .rateLimited(retryAfterSeconds: retryAfterSeconds(in: message)), message: description)
        }
        if code == 401 || text.contains("AUTH_KEY_UNREGISTERED") || text.contains("SESSION_REVOKED") {
            return UploadError(kind: .authLost, message: description)
        }
        if text.contains("FILE_PARTS_INVALID") || (code == 400 && text.contains("FILE")) {
            return UploadError(kind: .permanent, message: description)
        }
        return UploadError(kind: .transient, message: description)
    }

    /// The wait Telegram asked for ("retry after 5", "FLOOD_WAIT_30"), or 30 seconds if it gave no number.
    private static func retryAfterSeconds(in message: String) -> Int {
        let digits = message.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).first
        return digits.flatMap { Int($0) } ?? 30
    }
}

/// What the account is in a chat, without TDLibKit types.
enum ChatMemberRole: Equatable {
    case creator
    case administrator(canPostMessages: Bool)
    case member
    case restricted(isMember: Bool, canSendDocuments: Bool)
    case left
    case banned
}

/// Decides which chats can receive the backup.
enum ChatWriteAccess {
    /// - Parameters:
    ///   - isChannel: A broadcast channel, where only admins post.
    ///   - role: What the account is in the chat.
    ///   - membersCanSendDocuments: The chat's default permission for ordinary members.
    static func canSend(isChannel: Bool, role: ChatMemberRole, membersCanSendDocuments: Bool) -> Bool {
        switch role {
        case .creator:
            return true
        case .administrator(let canPostMessages):
            return !isChannel || canPostMessages
        case .member:
            return !isChannel && membersCanSendDocuments
        case .restricted(let isMember, let canSendDocuments):
            return !isChannel && isMember && canSendDocuments
        case .left, .banned:
            return false
        }
    }
}
