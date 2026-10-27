/// The parameters of one sync run.
import Foundation

/// Finds new photos and videos and uploads them to Telegram.
public struct SyncRequest: Sendable {
    public var trigger: SyncTrigger
    public var deadline: Date?
    public var allowCellular: Bool
    public var settings: SyncSettings

    /// Creates a request; no deadline, Wi-Fi only and default settings unless given.
    public init(
        trigger: SyncTrigger,
        deadline: Date? = nil,
        allowCellular: Bool = false,
        settings: SyncSettings = SyncSettings()
    ) {
        self.trigger = trigger
        self.deadline = deadline
        self.allowCellular = allowCellular
        self.settings = settings
    }
}
public actor SyncEngine {
    let library: PhotoLibrary
    let uploader: TelegramUploader
    let store: StateStore
    let environment: EnvironmentProbe
    let places: PlaceResolver
    let clock: Clock
    let timeZone: TimeZone
    let workDirectory: URL
    let observer: SyncObserver?

    /// Creates an engine that talks to the outside world only through the given ports.
    public init(
        library: PhotoLibrary,
        uploader: TelegramUploader,
        store: StateStore,
        environment: EnvironmentProbe,
        places: PlaceResolver,
        clock: Clock,
        timeZone: TimeZone,
        workDirectory: URL,
        observer: SyncObserver?
    ) {
        self.library = library
        self.uploader = uploader
        self.store = store
        self.environment = environment
        self.places = places
        self.clock = clock
        self.timeZone = timeZone
        self.workDirectory = workDirectory
        self.observer = observer
    }

    /// Stores new library assets as pending units and applies the screenshot setting; returns how many units were added.
    public func discover(settings: SyncSettings) async throws -> Int {
        guard await library.authorization() == .full else {
            throw UploadError(kind: .permanent, message: "noLibraryAccess")
        }
        let baseline = try await baselineDate()
        let known = try await store.knownAssetIdentifiers()
        let assets = try await library.allAssets()

        var newUnits: [UploadUnit] = []
        for asset in assets where !known.contains(asset.localIdentifier) {
            newUnits.append(contentsOf: units(for: asset, baseline: baseline))
        }
        try await store.insert(newUnits)
        try await applyScreenshotSetting(settings.includeScreenshots)
        return newUnits.count
    }

    /// The stored baseline date; it is set to now the first time (or when the stored value is unreadable).
    private func baselineDate() async throws -> Date {
        if let text = try await store.meta(.baselineDate), let date = Self.parseISO8601(text) {
            return date
        }
        let now = clock.now()
        try await store.setMeta(.baselineDate, Self.formatISO8601(now))
        return now
    }

    private func units(for asset: AssetDescriptor, baseline: Date) -> [UploadUnit] {
        let tag = AssetTag.make(localIdentifier: asset.localIdentifier)
        let isBackfill = (asset.creationDate ?? .distantPast) < baseline
        return ResourcePlanner.plan(asset).map { planned in
            UploadUnit(
                id: "\(asset.localIdentifier)|\(planned.role.rawValue)",
                assetLocalIdentifier: asset.localIdentifier,
                assetTag: tag,
                role: planned.role,
                resourceKind: planned.resourceKind,
                uploadFilename: planned.uploadFilename,
                byteSize: planned.byteSize,
                creationDate: asset.creationDate,
                isBackfill: isBackfill,
                isScreenshotOrRecording: asset.isScreenshotOrRecording,
                location: asset.location,
                status: .pending
            )
        }
    }

    private func applyScreenshotSetting(_ includeScreenshots: Bool) async throws {
        for var unit in try await store.allUnits() {
            if !includeScreenshots, unit.status == .pending, unit.isScreenshotOrRecording {
                unit.status = .skipped
                unit.skipReason = .screenshotsDisabled
            } else if includeScreenshots, unit.status == .skipped, unit.skipReason == .screenshotsDisabled {
                unit.status = .pending
                unit.skipReason = nil
            } else {
                continue
            }
            try await store.update(unit)
        }
    }

    private static func formatISO8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func parseISO8601(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}
