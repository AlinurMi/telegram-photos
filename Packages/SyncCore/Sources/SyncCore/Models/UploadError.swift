/// The category of an upload failure, which decides how it is retried.
import Foundation

/// An upload failure with a category and a short, non-sensitive message.
public enum UploadErrorKind: Codable, Sendable, Equatable {
    case transient
    case rateLimited(retryAfterSeconds: Int)
    case permanent
    case notLocal
    case tooLarge
    case cancelled
    case authLost
}
public struct UploadError: Error, Codable, Sendable, Equatable {
    public var kind: UploadErrorKind
    public var message: String

    /// Creates an upload error.
    public init(kind: UploadErrorKind, message: String) {
        self.kind = kind
        self.message = message
    }
}
