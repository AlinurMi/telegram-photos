import Foundation

/// Which part of an asset an upload unit carries.
public enum UnitRole: String, Codable, Sendable, CaseIterable { case primary, raw, live, edit }

/// Where an upload unit is in its life cycle.
public enum UnitStatus: String, Codable, Sendable { case pending, uploading, done, failed, skipped }

/// Why an upload unit was skipped instead of uploaded.
public enum SkipReason: String, Codable, Sendable { case notLocal, tooLarge, screenshotsDisabled }

/// One file to upload to Telegram, with its sync state.
public struct UploadUnit: Codable, Sendable, Equatable, Identifiable {
    /// `"<localIdentifier>|<role>"`, or `"<localIdentifier>|edit|<unix modificationDate>"` for edits.
    public var id: String
    public var assetLocalIdentifier: String
    public var assetTag: String
    public var role: UnitRole
    public var resourceKind: ResourceKind
    public var uploadFilename: String
    public var byteSize: Int64?
    public var creationDate: Date?
    public var isBackfill: Bool
    public var isScreenshotOrRecording: Bool
    public var location: Coordinate?
    public var status: UnitStatus
    public var skipReason: SkipReason?
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    public var messageId: Int64?
    public var uploadedAt: Date?
    /// The asset's modification date when this unit was planned; edits are detected against it.
    public var assetModifiedAt: Date?

    /// Creates an upload unit; new units start `pending` with no attempts.
    public init(
        id: String,
        assetLocalIdentifier: String,
        assetTag: String,
        role: UnitRole,
        resourceKind: ResourceKind,
        uploadFilename: String,
        byteSize: Int64? = nil,
        creationDate: Date? = nil,
        isBackfill: Bool = false,
        isScreenshotOrRecording: Bool = false,
        location: Coordinate? = nil,
        status: UnitStatus = .pending,
        skipReason: SkipReason? = nil,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil,
        messageId: Int64? = nil,
        uploadedAt: Date? = nil,
        assetModifiedAt: Date? = nil
    ) {
        self.id = id
        self.assetLocalIdentifier = assetLocalIdentifier
        self.assetTag = assetTag
        self.role = role
        self.resourceKind = resourceKind
        self.uploadFilename = uploadFilename
        self.byteSize = byteSize
        self.creationDate = creationDate
        self.isBackfill = isBackfill
        self.isScreenshotOrRecording = isScreenshotOrRecording
        self.location = location
        self.status = status
        self.skipReason = skipReason
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.messageId = messageId
        self.uploadedAt = uploadedAt
        self.assetModifiedAt = assetModifiedAt
    }
}
