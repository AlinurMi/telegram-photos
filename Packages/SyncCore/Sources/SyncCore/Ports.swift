import Foundation

/// How much of the photo library the app may read.
public enum LibraryAuthorization: Sendable { case full, limited, denied, notDetermined }

/// Whether the network can be used for uploads.
public enum NetworkState: Sendable { case unavailable, expensive, ok }

/// Read access to the user's photo library.
public protocol PhotoLibrary: Sendable {
    /// Current permission level.
    func authorization() async -> LibraryAuthorization

    /// User library only, hidden excluded, bursts expanded to representative + user picks, any order.
    func allAssets() async throws -> [AssetDescriptor]

    /// Writes the resource to `fileURL` (parent dir exists). Throws `UploadError(.notLocal)` if only in iCloud.
    func export(assetLocalIdentifier: String, resourceKind: ResourceKind, to fileURL: URL) async throws
}

/// The Telegram side: sending files and searching the destination chat.
public protocol TelegramUploader: Sendable {
    /// Largest file the account can send, in bytes.
    func maxFileSize() async -> Int64

    /// Returns the final server message id. Throws `UploadError`.
    func sendDocument(
        fileURL: URL,
        caption: Caption,
        progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void
    ) async throws -> Int64

    /// Searches the destination chat for a message whose caption contains `#<assetTag>` and the role's tag.
    func findMessage(assetTag: String, role: UnitRole) async throws -> Int64?

    /// Captions of all document messages in the destination chat, newest first.
    func allDocumentCaptions() -> AsyncThrowingStream<String, Error>
}

/// Keys of the small key-value area in the state store.
public enum MetaKey: String, Sendable { case baselineDate, lastSuccessfulSyncAt, lastReportJSON }

/// Persistent sync state.
public protocol StateStore: Sendable {
    /// Reads a meta value.
    func meta(_ key: MetaKey) async throws -> String?

    /// Writes a meta value; `nil` removes it.
    func setMeta(_ key: MetaKey, _ value: String?) async throws

    /// Local identifiers of every asset that already has at least one unit.
    func knownAssetIdentifiers() async throws -> Set<String>

    /// Adds units, ignoring ids that already exist.
    func insert(_ units: [UploadUnit]) async throws

    /// Every stored unit, in no particular order.
    func allUnits() async throws -> [UploadUnit]

    /// Replaces the stored unit that has the same id; does nothing if it doesn't exist.
    func update(_ unit: UploadUnit) async throws

    /// Units per state; `backfillPending` is the subset of `pending` that is backfill.
    func counts() async throws -> StatusCounts

    /// A previously resolved place name, if any.
    func cachedPlace(key: String) async throws -> String?

    /// Remembers a resolved place name.
    func storePlace(key: String, name: String) async throws

    /// Wipes units and meta, keeping the place cache.
    func resetAll() async throws
}

/// The device conditions that decide whether syncing is allowed.
public protocol EnvironmentProbe: Sendable {
    /// Current network state.
    func networkState() async -> NetworkState

    /// Whether the phone is plugged in (charging or full).
    func isCharging() async -> Bool

    /// Free storage in bytes.
    func freeDiskBytes() async -> Int64
}

/// Turns a coordinate into a place name, or `nil` if unknown.
public protocol PlaceResolver: Sendable {
    /// The place name for `coordinate`, if one can be found.
    func placeName(for coordinate: Coordinate) async -> String?
}

/// The source of the current time.
public protocol Clock: Sendable {
    /// The current date.
    func now() -> Date
}

/// Progress notifications from a sync run.
public enum SyncEvent: Sendable, Equatable {
    case runStarted(total: Int, totalBytes: Int64)
    // `index` counts from zero.
    case unitStarted(index: Int, total: Int, fileName: String, bytes: Int64?)
    case unitProgress(sent: Int64, total: Int64)
    case unitFinished(index: Int, total: Int, status: UnitStatus)
    case runFinished(SyncReport)
}

/// Receives events from a sync run.
public protocol SyncObserver: Sendable {
    /// Called for each event, in order.
    func handle(_ event: SyncEvent) async
}
