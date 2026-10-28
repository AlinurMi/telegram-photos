import Foundation
import SyncCore

/// Waits until Telegram is logged in. `TelegramService` is the real one; tests use a stand-in.
protocol TelegramReadiness: Sendable {
    /// Returns once logged in. Throws `UploadError` (`.authLost` if the owner must log in again).
    func waitUntilReady(timeout: TimeInterval) async throws
}

extension TelegramService: TelegramReadiness {}

/// Why a coordinator action could not start.
enum CoordinatorError: Error, Equatable {
    /// A sync run or another maintenance action is already in progress.
    case busy
}

/// Passes each engine event on to every observer, in order.
final class SyncEventBus: SyncObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [any SyncObserver] = []

    func add(_ observer: any SyncObserver) {
        lock.lock()
        observers.append(observer)
        lock.unlock()
    }

    func handle(_ event: SyncEvent) async {
        for observer in snapshot() {
            await observer.handle(event)
        }
    }

    private func snapshot() -> [any SyncObserver] {
        lock.lock()
        defer { lock.unlock() }
        return observers
    }
}

/// Wires the engine to the app: one sync at a time, state for the screens, and the maintenance actions.
actor SyncCoordinator {
    private static let readyTimeout: TimeInterval = 30

    private let engine: SyncEngine
    private let store: StateStore
    private let readiness: TelegramReadiness
    private let settings: AppSettings
    private let model: AppModel
    private let clock: Clock
    private let workDirectory: URL
    private let logger: FileLogger
    private let bus = SyncEventBus()
    private var isBusy = false
    private var currentRun: Task<SyncReport, Never>?

    /// Builds the engine once from the adapters. `model` is always the first observer of its events.
    init(
        library: PhotoLibrary,
        uploader: TelegramUploader,
        readiness: TelegramReadiness,
        store: StateStore,
        environment: EnvironmentProbe,
        places: PlaceResolver,
        clock: Clock,
        timeZone: TimeZone = .current,
        workDirectory: URL,
        settings: AppSettings,
        model: AppModel,
        logger: FileLogger = .shared
    ) {
        self.store = store
        self.readiness = readiness
        self.settings = settings
        self.model = model
        self.clock = clock
        self.workDirectory = workDirectory
        self.logger = logger
        bus.add(model)
        engine = SyncEngine(
            library: library,
            uploader: uploader,
            store: store,
            environment: environment,
            places: places,
            clock: clock,
            timeZone: timeZone,
            workDirectory: workDirectory,
            observer: bus)
    }

    /// The one coordinator the app uses, built from the real adapters.
    @MainActor static let shared = makeLive()

    @MainActor private static func makeLive() -> SyncCoordinator {
        let store: StateStore
        do {
            store = try GRDBStateStore(directory: GRDBStateStore.defaultDirectory())
        } catch {
            FileLogger.shared.error("Could not open the sync database: \(type(of: error))", category: "sync")
            store = UnavailableStateStore()
        }
        let telegram = TelegramService.shared
        return SyncCoordinator(
            library: PhotoKitLibrary(),
            uploader: telegram,
            readiness: telegram,
            store: store,
            environment: SystemEnvironment(),
            places: MapKitPlaceResolver(),
            clock: SystemClock(),
            workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("uploads", isDirectory: true),
            settings: .shared,
            model: .shared)
    }

    /// Also sends every sync event to `observer` (the Live Activity, a background task's progress).
    func addObserver(_ observer: any SyncObserver) {
        bus.add(observer)
    }

    /// Runs one sync and returns its report, or `nil` if a run is already in progress.
    ///
    /// The run lives in its own task, so cancelling the caller does not stop it; use `cancelCurrentRun()`.
    func sync(trigger: SyncTrigger, deadline: Date? = nil, allowCellular: Bool = false) async -> SyncReport? {
        guard !isBusy else {
            logger.info("Sync (\(trigger.rawValue)) ignored: already busy", category: "sync")
            return nil
        }
        isBusy = true
        let run = Task { await self.execute(trigger: trigger, deadline: deadline, allowCellular: allowCellular) }
        currentRun = run
        let report = await run.value
        currentRun = nil
        isBusy = false
        return report
    }

    /// Asks the running sync to stop after the current step. Does nothing if none is running.
    func cancelCurrentRun() {
        currentRun?.cancel()
    }

    /// Called once per launch, when the app first becomes active: loads the numbers, then syncs if setup is done.
    func syncOnLaunch() async {
        await refreshState(restoreReport: true)
        guard settings.setupCompleted else { return }
        _ = await sync(trigger: .appLaunch)
    }

    /// Re-reads the counts and the last sync time into the model.
    func refreshState() async {
        await refreshState(restoreReport: false)
    }

    /// Marks setup as done and records the baseline date (only if there isn't one yet).
    func finishSetup() async throws {
        if try await store.meta(.baselineDate) == nil {
            try await store.setMeta(.baselineDate, Self.formatISO8601(clock.now()))
        }
        settings.setupCompleted = true
        await refreshState()
    }

    /// Marks everything already in the channel as done; returns how many units changed.
    func rebuild() async throws -> Int {
        try beginExclusive()
        defer { isBusy = false }
        try await readiness.waitUntilReady(timeout: Self.readyTimeout)
        let changed = try await engine.rebuildFromChannel(settings: settings.syncSettings)
        await refreshState()
        return changed
    }

    /// Gives every failed unit a fresh retry budget; returns how many were reset.
    func retryFailed() async throws -> Int {
        try beginExclusive()
        defer { isBusy = false }
        let changed = try await engine.retryFailed()
        await refreshState()
        return changed
    }

    /// Wipes the sync state (units and baseline). The Telegram login and the settings stay.
    func resetState() async throws {
        try beginExclusive()
        defer { isBusy = false }
        try await store.resetAll()
        await model.clearReport()
        await refreshState()
    }

    private func beginExclusive() throws {
        guard !isBusy else { throw CoordinatorError.busy }
        isBusy = true
    }

    private func execute(trigger: SyncTrigger, deadline: Date?, allowCellular: Bool) async -> SyncReport {
        let startedAt = clock.now()
        await model.runBegan()
        logger.info("Sync started: \(trigger.rawValue), cellular allowed: \(allowCellular)", category: "sync")
        // Only one run exists at a time, so anything left here is from an interrupted run.
        try? FileManager.default.removeItem(at: workDirectory)

        let report: SyncReport
        if let block = await telegramBlock() {
            report = SyncReport(
                trigger: trigger, startedAt: startedAt, endedAt: clock.now(),
                uploaded: 0, failed: 0, skipped: 0, remainingEligible: 0, blockedBy: block)
            await bus.handle(.runFinished(report))
        } else {
            let request = SyncRequest(
                trigger: trigger, deadline: deadline, allowCellular: allowCellular, settings: settings.syncSettings)
            report = await engine.runOnce(request)
        }
        await refreshState()
        let reason = report.blockedBy?.rawValue ?? "none"
        logger.info(
            "Sync finished: uploaded \(report.uploaded), failed \(report.failed), skipped \(report.skipped), blocked by \(reason)",
            category: "sync")
        return report
    }

    /// `nil` when Telegram is ready; otherwise the reason the run can't start.
    private func telegramBlock() async -> BlockReason? {
        do {
            try await readiness.waitUntilReady(timeout: Self.readyTimeout)
            return nil
        } catch let error as UploadError {
            switch error.kind {
            case .authLost: return .authLost
            case .cancelled: return .cancelled
            default: return .noNetwork
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .noNetwork
        }
    }

    private func refreshState(restoreReport: Bool) async {
        do {
            let counts = try await store.counts()
            let lastSyncAt = try await store.meta(.lastSuccessfulSyncAt).flatMap(Self.parseISO8601)
            await model.update(counts: counts, lastSyncAt: lastSyncAt)
            if restoreReport, let json = try await store.meta(.lastReportJSON), let report = Self.decodeReport(json) {
                await model.restore(report: report)
            }
        } catch {
            logger.error("Could not read the sync state: \(type(of: error))", category: "sync")
        }
    }

    private static func decodeReport(_ json: String) -> SyncReport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncReport.self, from: Data(json.utf8))
    }

    private static func formatISO8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func parseISO8601(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}

/// Stands in when the database can't be opened: every call fails, so a run ends early instead of crashing.
struct UnavailableStateStore: StateStore {
    func meta(_ key: MetaKey) async throws -> String? { throw StateStoreError.unavailable }
    func setMeta(_ key: MetaKey, _ value: String?) async throws { throw StateStoreError.unavailable }
    func knownAssetIdentifiers() async throws -> Set<String> { throw StateStoreError.unavailable }
    func insert(_ units: [UploadUnit]) async throws { throw StateStoreError.unavailable }
    func allUnits() async throws -> [UploadUnit] { throw StateStoreError.unavailable }
    func update(_ unit: UploadUnit) async throws { throw StateStoreError.unavailable }
    func counts() async throws -> StatusCounts { throw StateStoreError.unavailable }
    func cachedPlace(key: String) async throws -> String? { throw StateStoreError.unavailable }
    func storePlace(key: String, name: String) async throws { throw StateStoreError.unavailable }
    func resetAll() async throws { throw StateStoreError.unavailable }
}
