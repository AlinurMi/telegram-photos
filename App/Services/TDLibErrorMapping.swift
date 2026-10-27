/// A Telegram request failed. `message` is short, plain and safe to show to the owner.
import Foundation

/// Turns TDLib error codes into plain messages for the owner.
///
/// Takes the raw code and text so it stays free of TDLibKit types.
struct TelegramError: Error, LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}
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
}
