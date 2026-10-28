import SyncCore
import XCTest

@testable import TelegramPhotos

/// Lets a test hold a stand-in inside a call until it chooses to let go.
private actor Gate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by the stand-in: reports that it got here, then waits for `release()`.
    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

private struct StubLibrary: PhotoLibrary {
    var gate: Gate?

    func authorization() async -> LibraryAuthorization {
        await gate?.enterAndWait()
        return .full
    }

    func allAssets() async throws -> [AssetDescriptor] { [] }

    func export(assetLocalIdentifier: String, resourceKind: ResourceKind, to fileURL: URL) async throws {
        throw UploadError(kind: .permanent, message: "unused")
    }
}

private struct StubUploader: TelegramUploader {
    func maxFileSize() async -> Int64 { 2_000_000_000 }

    func sendDocument(
        fileURL: URL,
        caption: Caption,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Int64 {
        throw UploadError(kind: .permanent, message: "unused")
    }

    func findMessage(assetTag: String, role: UnitRole) async throws -> Int64? { nil }

    func allDocumentCaptions() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct StubEnvironment: EnvironmentProbe {
    func networkState() async -> NetworkState { .ok }
    func isCharging() async -> Bool { true }
    func freeDiskBytes() async -> Int64 { 10_000_000_000 }
}

private struct StubPlaces: PlaceResolver {
    func placeName(for coordinate: Coordinate) async -> String? { nil }
}

private struct StubReadiness: TelegramReadiness {
    var error: UploadError?
    var logOutError: UploadError?

    func waitUntilReady(timeout: TimeInterval) async throws {
        if let error { throw error }
    }

    func logOut() async throws {
        if let logOutError { throw logOutError }
    }
}

private final class EventRecorder: SyncObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SyncEvent] = []

    var events: [SyncEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func handle(_ event: SyncEvent) async {
        record(event)
    }

    private func record(_ event: SyncEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private struct Fixture {
        let coordinator: SyncCoordinator
        let store: GRDBStateStore
        let model: AppModel
        let settings: AppSettings
    }

    private func makeFixture(
        gate: Gate? = nil,
        readinessError: UploadError? = nil,
        logOutError: UploadError? = nil,
        afterRun: @escaping @Sendable () -> Void = {}
    ) throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "SyncCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = try GRDBStateStore(directory: directory.appendingPathComponent("db", isDirectory: true))
        let model = AppModel()
        let settings = AppSettings(defaults: defaults)
        let coordinator = SyncCoordinator(
            library: StubLibrary(gate: gate),
            uploader: StubUploader(),
            readiness: StubReadiness(error: readinessError, logOutError: logOutError),
            store: store,
            environment: StubEnvironment(),
            places: StubPlaces(),
            clock: SystemClock(),
            workDirectory: directory.appendingPathComponent("uploads", isDirectory: true),
            settings: settings,
            model: model,
            afterRun: afterRun)
        return Fixture(coordinator: coordinator, store: store, model: model, settings: settings)
    }

    func testEveryRunCallsAfterRun() async throws {
        let counter = CallCounter()
        let fixture = try makeFixture(
            readinessError: UploadError(kind: .authLost, message: "notLoggedIn"),
            afterRun: { counter.increment() })

        _ = await fixture.coordinator.sync(trigger: .manual)
        XCTAssertEqual(counter.count, 1)
        _ = await fixture.coordinator.sync(trigger: .backgroundProcessing)
        XCTAssertEqual(counter.count, 2)
        _ = try? await fixture.coordinator.retryFailed()
        XCTAssertEqual(counter.count, 2)
    }

    func testSyncWithNothingToDoReportsAndNotifiesObservers() async throws {
        let fixture = try makeFixture()
        let recorder = EventRecorder()
        await fixture.coordinator.addObserver(recorder)

        let result = await fixture.coordinator.sync(trigger: .manual)
        let report = try XCTUnwrap(result)

        XCTAssertEqual(report.uploaded, 0)
        XCTAssertNil(report.blockedBy)
        XCTAssertEqual(recorder.events.first, .runStarted(total: 0, totalBytes: 0))
        XCTAssertEqual(recorder.events.last, .runFinished(report))
        XCTAssertEqual(fixture.model.phase, .idle)
        XCTAssertEqual(fixture.model.lastReport, report)
    }

    func testLoggedOutTelegramBlocksTheRun() async throws {
        let fixture = try makeFixture(readinessError: UploadError(kind: .authLost, message: "notLoggedIn"))
        let recorder = EventRecorder()
        await fixture.coordinator.addObserver(recorder)

        let result = await fixture.coordinator.sync(trigger: .backgroundProcessing)
        let report = try XCTUnwrap(result)

        XCTAssertEqual(report.blockedBy, .authLost)
        XCTAssertEqual(report.uploaded, 0)
        XCTAssertEqual(recorder.events, [.runFinished(report)])
        XCTAssertEqual(fixture.model.phase, .blocked(.authLost))
    }

    func testReturnToLoginReopensSetupAndKeepsTheBaseline() async throws {
        let fixture = try makeFixture(readinessError: UploadError(kind: .authLost, message: "notLoggedIn"))
        try await fixture.coordinator.finishSetup()
        let baseline = try await fixture.store.meta(.baselineDate)
        _ = await fixture.coordinator.sync(trigger: .manual)
        XCTAssertEqual(fixture.model.phase, .blocked(.authLost))

        await fixture.coordinator.returnToLogin()

        XCTAssertFalse(fixture.settings.setupCompleted)
        XCTAssertEqual(fixture.model.phase, .idle)
        let after = try await fixture.store.meta(.baselineDate)
        XCTAssertEqual(after, baseline)
    }

    func testOnlyOneRunAtATime() async throws {
        let gate = Gate()
        let fixture = try makeFixture(gate: gate)

        let first = Task { await fixture.coordinator.sync(trigger: .manual) }
        await gate.waitUntilEntered()

        let second = await fixture.coordinator.sync(trigger: .appLaunch)
        XCTAssertNil(second)
        do {
            _ = try await fixture.coordinator.retryFailed()
            XCTFail("retryFailed should refuse while a run is active")
        } catch {
            XCTAssertEqual(error as? CoordinatorError, .busy)
        }

        await gate.release()
        let firstReport = await first.value
        XCTAssertNotNil(firstReport)

        let third = await fixture.coordinator.sync(trigger: .manual)
        XCTAssertNotNil(third)
    }

    func testFinishSetupRecordsTheBaselineOnce() async throws {
        let fixture = try makeFixture()
        let before = try await fixture.store.meta(.baselineDate)
        XCTAssertNil(before)
        XCTAssertFalse(fixture.settings.setupCompleted)

        try await fixture.coordinator.finishSetup()
        let first = try await fixture.store.meta(.baselineDate)
        XCTAssertNotNil(first.flatMap { ISO8601DateFormatter().date(from: $0) })
        XCTAssertTrue(fixture.settings.setupCompleted)

        try await fixture.store.setMeta(.baselineDate, "2020-01-01T00:00:00Z")
        try await fixture.coordinator.finishSetup()
        let second = try await fixture.store.meta(.baselineDate)
        XCTAssertEqual(second, "2020-01-01T00:00:00Z")
    }

    func testLaunchSyncWaitsForSetup() async throws {
        let fixture = try makeFixture()
        let recorder = EventRecorder()
        await fixture.coordinator.addObserver(recorder)

        await fixture.coordinator.syncOnLaunch()
        XCTAssertTrue(recorder.events.isEmpty)

        try await fixture.coordinator.finishSetup()
        await fixture.coordinator.syncOnLaunch()
        let finished = recorder.events.compactMap { event -> SyncTrigger? in
            if case .runFinished(let report) = event { return report.trigger }
            return nil
        }
        XCTAssertEqual(finished, [.appLaunch])
    }

    func testRefreshStateLoadsCountsAndLastSyncTime() async throws {
        let fixture = try makeFixture()
        let unit = UploadUnit(
            id: "A|primary",
            assetLocalIdentifier: "A",
            assetTag: AssetTag.make(localIdentifier: "A"),
            role: .primary,
            resourceKind: .photo,
            uploadFilename: "IMG_1.HEIC")
        try await fixture.store.insert([unit])
        try await fixture.store.setMeta(.lastSuccessfulSyncAt, "2026-10-27T12:00:00Z")

        await fixture.coordinator.refreshState()

        XCTAssertEqual(fixture.model.counts.pending, 1)
        XCTAssertNotNil(fixture.model.lastSyncAt)
    }

    func testResetStateClearsUnitsAndBaseline() async throws {
        let fixture = try makeFixture()
        let unit = UploadUnit(
            id: "A|primary",
            assetLocalIdentifier: "A",
            assetTag: AssetTag.make(localIdentifier: "A"),
            role: .primary,
            resourceKind: .photo,
            uploadFilename: "IMG_1.HEIC")
        try await fixture.store.insert([unit])
        try await fixture.coordinator.finishSetup()

        try await fixture.coordinator.resetState()

        let baseline = try await fixture.store.meta(.baselineDate)
        XCTAssertNil(baseline)
        XCTAssertEqual(fixture.model.counts, StatusCounts())
        XCTAssertNil(fixture.model.lastReport)
    }

    func testLogOutForgetsTheDestinationAndReopensSetup() async throws {
        let fixture = try makeFixture()
        fixture.settings.destinationChatId = 42
        fixture.settings.destinationTitle = "Backup"
        try await fixture.coordinator.finishSetup()
        let baseline = try await fixture.store.meta(.baselineDate)

        try await fixture.coordinator.logOut()

        XCTAssertFalse(fixture.settings.setupCompleted)
        XCTAssertNil(fixture.settings.destinationChatId)
        XCTAssertNil(fixture.settings.destinationTitle)
        let after = try await fixture.store.meta(.baselineDate)
        XCTAssertEqual(after, baseline)
    }

    func testFailedLogOutKeepsEverything() async throws {
        let fixture = try makeFixture(logOutError: UploadError(kind: .transient, message: "offline"))
        fixture.settings.destinationChatId = 42
        try await fixture.coordinator.finishSetup()

        do {
            try await fixture.coordinator.logOut()
            XCTFail("logOut should pass the error on")
        } catch {
            XCTAssertEqual((error as? UploadError)?.kind, .transient)
        }

        XCTAssertTrue(fixture.settings.setupCompleted)
        XCTAssertEqual(fixture.settings.destinationChatId, 42)
        let third = await fixture.coordinator.sync(trigger: .manual)
        XCTAssertNotNil(third, "a failed logout must not leave the coordinator busy")
    }

    func testLogOutRefusesDuringARun() async throws {
        let gate = Gate()
        let fixture = try makeFixture(gate: gate)
        try await fixture.coordinator.finishSetup()

        let run = Task { await fixture.coordinator.sync(trigger: .manual) }
        await gate.waitUntilEntered()
        do {
            try await fixture.coordinator.logOut()
            XCTFail("logOut should refuse while a run is active")
        } catch {
            XCTAssertEqual(error as? CoordinatorError, .busy)
        }
        await gate.release()
        _ = await run.value

        XCTAssertTrue(fixture.settings.setupCompleted)
    }

    func testAdvancedDetailsShowBaselineAndPrettyReport() async throws {
        let fixture = try makeFixture()
        let empty = await fixture.coordinator.advancedDetails()
        XCTAssertEqual(empty, AdvancedDetails())

        try await fixture.store.setMeta(.baselineDate, "2026-10-27T12:00:00Z")
        try await fixture.store.setMeta(.lastReportJSON, #"{"uploaded":3,"failed":0}"#)

        let details = await fixture.coordinator.advancedDetails()

        XCTAssertEqual(details.baselineDate, ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z"))
        XCTAssertEqual(details.lastReportJSON, "{\n  \"failed\" : 0,\n  \"uploaded\" : 3\n}")
    }

    func testPrettyJSONLeavesOtherTextAlone() {
        XCTAssertEqual(SyncCoordinator.prettyJSON("not json"), "not json")
        XCTAssertEqual(
            SyncCoordinator.prettyJSON(#"{"b":1,"a":[true]}"#), "{\n  \"a\" : [\n    true\n  ],\n  \"b\" : 1\n}")
    }
}
