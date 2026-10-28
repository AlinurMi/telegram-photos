import Foundation

/// Checks the Telegram API details the owner types in.
enum CredentialsValidator {
    /// The API ID if `text` is digits only and greater than zero.
    static func apiId(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    /// Whether `text` is exactly 32 hexadecimal characters.
    static func isValidApiHash(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 32 && trimmed.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
