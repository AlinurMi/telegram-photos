import Foundation

/// The parameters of one sync run.
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

/// Finds new photos and videos and uploads them to Telegram.
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

    /// Stores new library assets as pending units, adds `#edit` units for re-edited uploaded assets when
    /// `settings.resendEdits` is on, and applies the screenshot setting; returns how many units were added.
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
        let editUnits = try await trackEdits(
            of: assets.filter { known.contains($0.localIdentifier) }, resend: settings.resendEdits)
        try await store.insert(editUnits)
        try await applyScreenshotSetting(settings.includeScreenshots)
        return newUnits.count + editUnits.count
    }

    /// Runs one sync: discovers new assets, resolves interrupted uploads, then uploads eligible units until
    /// done or blocked. Never throws; failures are reflected in the returned report, which is also stored.
    public func runOnce(_ request: SyncRequest) async -> SyncReport {
        let startedAt = clock.now()
        var tally = RunTally()
        do {
            try await perform(request, tally: &tally)
        } catch let error as UploadError where error.message == Self.noLibraryAccessMessage {
            tally.blockedBy = .noLibraryAccess
        } catch {
            // A storage failure ends the run early; the report still shows what happened up to that point.
        }
        return await finish(request, startedAt: startedAt, tally: tally)
    }

    /// Marks every unit whose caption is found in the channel as `done` (without a message id); returns how many changed.
    /// The channel is read completely before anything is changed, so a failure leaves the state untouched.
    public func rebuildFromChannel(settings: SyncSettings = SyncSettings()) async throws -> Int {
        _ = try await discover(settings: settings)
        var uploaded: Set<ChannelEntry> = []
        for try await caption in uploader.allDocumentCaptions() {
            if let parsed = ChannelIndexParser.parse(caption: caption) {
                uploaded.insert(ChannelEntry(assetTag: parsed.assetTag, role: parsed.role))
            }
        }

        var changed = 0
        for var unit in try await store.allUnits() where unit.status != .done {
            guard uploaded.contains(ChannelEntry(assetTag: unit.assetTag, role: unit.role)) else { continue }
            unit.status = .done
            unit.skipReason = nil
            unit.lastError = nil
            unit.nextAttemptAt = nil
            try await store.update(unit)
            changed += 1
        }
        return changed
    }

    /// Puts every `failed` unit back to `pending` with a fresh retry budget; returns how many were reset.
    public func retryFailed() async throws -> Int {
        var changed = 0
        for var unit in try await store.allUnits() where unit.status == .failed {
            unit.status = .pending
            unit.attempts = 0
            unit.nextAttemptAt = nil
            try await store.update(unit)
            changed += 1
        }
        return changed
    }

    private struct ChannelEntry: Hashable {
        var assetTag: String
        var role: UnitRole
    }

    private static let noLibraryAccessMessage = "noLibraryAccess"
    private static let minimumFreeDiskMargin: Int64 = 200 * 1024 * 1024
    private static let deadlineMargin: TimeInterval = 5
    private static let editThreshold: TimeInterval = 60

    private struct RunTally {
        var uploaded = 0
        var failed = 0
        var skipped = 0
        var blockedBy: BlockReason?
    }

    private func perform(_ request: SyncRequest, tally: inout RunTally) async throws {
        _ = try await discover(settings: request.settings)
        if try await resolveInterruptedUploads() {
            tally.blockedBy = .authLost
            return
        }
        if let reason = await networkBlock(allowCellular: request.allowCellular) {
            tally.blockedBy = reason
            return
        }

        let charging = await environment.isCharging()
        let now = clock.now()
        let units = try await store.allUnits()
        let candidates = Eligibility.ordered(
            units.filter { Eligibility.isEligible($0, now: now, charging: charging, settings: request.settings) })
        await observer?.handle(
            .runStarted(total: candidates.count, totalBytes: candidates.reduce(0) { $0 + ($1.byteSize ?? 0) }))

        if candidates.isEmpty {
            let backfillWaitingForCharger =
                !charging
                && units.contains {
                    $0.isBackfill
                        && Eligibility.isEligible($0, now: now, charging: true, settings: request.settings)
                }
            if backfillWaitingForCharger { tally.blockedBy = .needsCharger }
            return
        }
        try await upload(candidates, request: request, tally: &tally)
    }

    /// Units left `uploading` by an interrupted run become `done` if their message is in the channel, else `pending`.
    /// Returns `true` if the run must stop because Telegram signed out.
    private func resolveInterruptedUploads() async throws -> Bool {
        let interrupted = Eligibility.ordered(try await store.allUnits().filter { $0.status == .uploading })
        for var unit in interrupted {
            let messageId: Int64?
            do {
                messageId = try await uploader.findMessage(assetTag: unit.assetTag, role: unit.role)
            } catch let error as UploadError where error.kind == .authLost {
                return true
            } catch {
                // Unknown outcome: leave the unit as it is so a later run can check again, rather than risk a duplicate.
                continue
            }
            if let messageId {
                unit.status = .done
                unit.messageId = messageId
                unit.uploadedAt = clock.now()
                unit.lastError = nil
            } else {
                unit.status = .pending
            }
            try await store.update(unit)
        }
        return false
    }

    private func networkBlock(allowCellular: Bool) async -> BlockReason? {
        switch await environment.networkState() {
        case .unavailable: return .noNetwork
        case .expensive: return allowCellular ? nil : .expensiveNetwork
        case .ok: return nil
        }
    }

    private func stopReason(for request: SyncRequest) async -> BlockReason? {
        if Task.isCancelled { return .cancelled }
        if let deadline = request.deadline, clock.now() > deadline.addingTimeInterval(-Self.deadlineMargin) {
            return .deadline
        }
        return await networkBlock(allowCellular: request.allowCellular)
    }

    private func upload(_ candidates: [UploadUnit], request: SyncRequest, tally: inout RunTally) async throws {
        let total = candidates.count
        let maxSize = await uploader.maxFileSize()

        for (index, candidate) in candidates.enumerated() {
            if let reason = await stopReason(for: request) {
                tally.blockedBy = reason
                return
            }
            var unit = candidate
            let size = unit.byteSize ?? 0

            if let known = unit.byteSize, known > maxSize {
                unit.status = .skipped
                unit.skipReason = .tooLarge
                try await store.update(unit)
                tally.skipped += 1
                await observer?.handle(.unitFinished(index: index, total: total, status: .skipped))
                continue
            }
            if await environment.freeDiskBytes() < size + Self.minimumFreeDiskMargin {
                tally.blockedBy = .lowDisk
                return
            }

            unit.status = .uploading
            try await store.update(unit)
            await observer?.handle(
                .unitStarted(index: index, total: total, fileName: unit.uploadFilename, bytes: unit.byteSize))

            var stop: BlockReason?
            do {
                let messageId = try await send(unit)
                let now = clock.now()
                unit.status = .done
                unit.messageId = messageId
                unit.uploadedAt = now
                unit.lastError = nil
                try await store.setMeta(.lastSuccessfulSyncAt, Self.formatISO8601(now))
                tally.uploaded += 1
            } catch {
                let failure = Self.uploadError(from: error)
                switch failure.kind {
                case .notLocal:
                    unit.status = .skipped
                    unit.skipReason = .notLocal
                    tally.skipped += 1
                case .tooLarge:
                    unit.status = .skipped
                    unit.skipReason = .tooLarge
                    tally.skipped += 1
                case .cancelled:
                    unit.status = .pending
                    stop = .cancelled
                case .authLost:
                    unit.status = .pending
                    stop = .authLost
                case .transient, .rateLimited, .permanent:
                    unit.attempts += 1
                    unit.lastError = failure.message
                    unit.nextAttemptAt = RetryPolicy.nextAttempt(
                        after: unit.attempts, error: failure.kind, now: clock.now())
                    if unit.nextAttemptAt == nil {
                        unit.status = .failed
                        tally.failed += 1
                    } else {
                        unit.status = .pending
                    }
                }
            }
            try await store.update(unit)
            await observer?.handle(.unitFinished(index: index, total: total, status: unit.status))
            if let stop {
                tally.blockedBy = stop
                return
            }
        }
    }

    /// Exports, captions and sends one unit, and always removes its work directory afterwards.
    private func send(_ unit: UploadUnit) async throws -> Int64 {
        let directory = workDirectory.appendingPathComponent(Self.sanitized(unit.id), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(unit.uploadFilename)
        try await library.export(
            assetLocalIdentifier: unit.assetLocalIdentifier, resourceKind: unit.resourceKind, to: fileURL)

        let place = try await placeName(for: unit.location)
        let caption = CaptionBuilder.build(unit: unit, placeName: place, timeZone: timeZone)

        // Progress is forwarded through a stream so events reach the observer in order and before the unit finishes.
        let (progress, continuation) = AsyncStream.makeStream(of: UploadProgress.self)
        let observer = self.observer
        let forwarder = Task {
            for await update in progress {
                await observer?.handle(.unitProgress(sent: update.sent, total: update.total))
            }
        }
        do {
            let messageId = try await uploader.sendDocument(fileURL: fileURL, caption: caption) { sent, total in
                continuation.yield(UploadProgress(sent: sent, total: total))
            }
            continuation.finish()
            await forwarder.value
            return messageId
        } catch {
            continuation.finish()
            await forwarder.value
            throw error
        }
    }

    private struct UploadProgress: Sendable {
        var sent: Int64
        var total: Int64
    }

    private func placeName(for location: Coordinate?) async throws -> String? {
        guard let location else { return nil }
        let key = String(format: "%.2f,%.2f", location.latitude, location.longitude)
        if let cached = try await store.cachedPlace(key: key) { return cached }
        guard let name = await places.placeName(for: location) else { return nil }
        try await store.storePlace(key: key, name: name)
        return name
    }

    private func finish(_ request: SyncRequest, startedAt: Date, tally: RunTally) async -> SyncReport {
        let remaining = await eligibleCount(settings: request.settings)
        let report = SyncReport(
            trigger: request.trigger,
            startedAt: startedAt,
            endedAt: clock.now(),
            uploaded: tally.uploaded,
            failed: tally.failed,
            skipped: tally.skipped,
            remainingEligible: remaining,
            blockedBy: tally.blockedBy)
        // Dates are encoded as ISO-8601 strings.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) {
            try? await store.setMeta(.lastReportJSON, json)
        }
        await observer?.handle(.runFinished(report))
        return report
    }

    private func eligibleCount(settings: SyncSettings) async -> Int {
        let charging = await environment.isCharging()
        let now = clock.now()
        guard let units = try? await store.allUnits() else { return 0 }
        return units.filter { Eligibility.isEligible($0, now: now, charging: charging, settings: settings) }.count
    }

    private static func sanitized(_ unitId: String) -> String {
        unitId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "|", with: "_")
    }

    /// Maps any thrown error to an `UploadError`; unknown errors are treated as transient, cancellation as cancelled.
    private static func uploadError(from error: Error) -> UploadError {
        if let error = error as? UploadError { return error }
        if error is CancellationError || Task.isCancelled {
            return UploadError(kind: .cancelled, message: "cancelled")
        }
        return UploadError(kind: .transient, message: "unexpectedError")
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
                status: .pending,
                assetModifiedAt: asset.modificationDate
            )
        }
    }

    /// Returns new `.edit` units for assets whose `done` primary unit is older than the asset's current
    /// modification date by more than `editThreshold` (compared with the newest edit unit, if any).
    /// While `resend` is off, or when a unit has no stored date yet, the stored date just follows the
    /// asset, so turning the setting on never re-sends edits made before.
    private func trackEdits(of assets: [AssetDescriptor], resend: Bool) async throws -> [UploadUnit] {
        guard !assets.isEmpty else { return [] }
        let stored = try await store.allUnits()
        let existingIds = Set(stored.map(\.id))
        let byAsset = Dictionary(grouping: stored, by: \.assetLocalIdentifier)

        var edits: [UploadUnit] = []
        for asset in assets {
            guard let modified = asset.modificationDate,
                let units = byAsset[asset.localIdentifier],
                var primary = units.first(where: { $0.role == .primary }),
                primary.status == .done
            else { continue }

            guard resend, let recorded = primary.assetModifiedAt else {
                if primary.assetModifiedAt.map({ modified > $0 }) ?? true {
                    primary.assetModifiedAt = modified
                    try await store.update(primary)
                }
                continue
            }
            let latest = units.filter { $0.role == .edit }.compactMap(\.assetModifiedAt).reduce(recorded, max)
            guard modified.timeIntervalSince(latest) > Self.editThreshold,
                let edit = editUnit(for: asset, modified: modified, tag: primary.assetTag),
                !existingIds.contains(edit.id)
            else { continue }
            edits.append(edit)
        }
        return edits
    }

    /// The current render of the asset's primary resource as a non-backfill `.edit` unit.
    private func editUnit(for asset: AssetDescriptor, modified: Date, tag: String) -> UploadUnit? {
        guard let planned = ResourcePlanner.plan(asset).first(where: { $0.role == .primary }) else { return nil }
        return UploadUnit(
            id: "\(asset.localIdentifier)|\(UnitRole.edit.rawValue)|\(Int(modified.timeIntervalSince1970))",
            assetLocalIdentifier: asset.localIdentifier,
            assetTag: tag,
            role: .edit,
            resourceKind: planned.resourceKind,
            uploadFilename: planned.uploadFilename,
            byteSize: planned.byteSize,
            creationDate: asset.creationDate,
            isBackfill: false,
            isScreenshotOrRecording: asset.isScreenshotOrRecording,
            location: asset.location,
            status: .pending,
            assetModifiedAt: modified
        )
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
