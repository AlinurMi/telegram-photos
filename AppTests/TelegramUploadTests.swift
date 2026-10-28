import SyncCore
import XCTest

@testable import TelegramPhotos

final class TelegramUploadTests: XCTestCase {
    // MARK: Error mapping

    func testRateLimitReadsTheWaitFromTheMessage() {
        let error = TDLibErrorMapping.uploadError(code: 429, message: "Too Many Requests: retry after 17")
        XCTAssertEqual(error.kind, .rateLimited(retryAfterSeconds: 17))
    }

    func testFloodWaitReadsTheWait() {
        let error = TDLibErrorMapping.uploadError(code: 420, message: "FLOOD_WAIT_30")
        XCTAssertEqual(error.kind, .rateLimited(retryAfterSeconds: 30))
    }

    func testRateLimitWithoutNumberWaitsThirtySeconds() {
        let error = TDLibErrorMapping.uploadError(code: 429, message: "Too Many Requests")
        XCTAssertEqual(error.kind, .rateLimited(retryAfterSeconds: 30))
    }

    func testLoginProblemsMeanAuthLost() {
        XCTAssertEqual(TDLibErrorMapping.uploadError(code: 401, message: "Unauthorized").kind, .authLost)
        XCTAssertEqual(
            TDLibErrorMapping.uploadError(code: 401, message: "AUTH_KEY_UNREGISTERED").kind, .authLost)
    }

    func testBadFileIsPermanent() {
        XCTAssertEqual(TDLibErrorMapping.uploadError(code: 400, message: "FILE_PARTS_INVALID").kind, .permanent)
        XCTAssertEqual(TDLibErrorMapping.uploadError(code: 400, message: "Wrong file identifier").kind, .permanent)
    }

    func testServerAndNetworkProblemsAreTransient() {
        XCTAssertEqual(TDLibErrorMapping.uploadError(code: 500, message: "Internal Server Error").kind, .transient)
        XCTAssertEqual(TDLibErrorMapping.uploadError(code: -1, message: "Timeout").kind, .transient)
        XCTAssertEqual(TDLibErrorMapping.uploadError(code: 400, message: "SOMETHING_NEW").kind, .transient)
    }

    // MARK: Who can post

    func testChannelsNeedAnAdminWhoCanPost() {
        XCTAssertTrue(ChatWriteAccess.canSend(isChannel: true, role: .creator, membersCanSendDocuments: true))
        XCTAssertTrue(
            ChatWriteAccess.canSend(
                isChannel: true, role: .administrator(canPostMessages: true), membersCanSendDocuments: false))
        XCTAssertFalse(
            ChatWriteAccess.canSend(
                isChannel: true, role: .administrator(canPostMessages: false), membersCanSendDocuments: true))
        XCTAssertFalse(ChatWriteAccess.canSend(isChannel: true, role: .member, membersCanSendDocuments: true))
    }

    func testGroupsFollowTheMemberPermissions() {
        XCTAssertTrue(ChatWriteAccess.canSend(isChannel: false, role: .member, membersCanSendDocuments: true))
        XCTAssertFalse(ChatWriteAccess.canSend(isChannel: false, role: .member, membersCanSendDocuments: false))
        XCTAssertTrue(
            ChatWriteAccess.canSend(
                isChannel: false, role: .administrator(canPostMessages: false), membersCanSendDocuments: false))
        XCTAssertTrue(
            ChatWriteAccess.canSend(
                isChannel: false, role: .restricted(isMember: true, canSendDocuments: true),
                membersCanSendDocuments: false))
        XCTAssertFalse(
            ChatWriteAccess.canSend(
                isChannel: false, role: .restricted(isMember: true, canSendDocuments: false),
                membersCanSendDocuments: true))
        XCTAssertFalse(ChatWriteAccess.canSend(isChannel: false, role: .left, membersCanSendDocuments: true))
        XCTAssertFalse(ChatWriteAccess.canSend(isChannel: false, role: .banned, membersCanSendDocuments: true))
    }

    // MARK: Send tracker

    func testResultThatArrivesFirstIsKept() async {
        let tracker = SendTracker()
        tracker.record(.sent(messageId: 900), for: 5)
        let outcome = await tracker.outcome(for: 5)
        XCTAssertEqual(outcome, .sent(messageId: 900))
    }

    func testWaitingCallerGetsTheResultWhenItArrives() async {
        let tracker = SendTracker()
        async let outcome = tracker.outcome(for: 7)
        try? await Task.sleep(nanoseconds: 50_000_000)
        tracker.record(.sent(messageId: 70), for: 7)
        let result = await outcome
        XCTAssertEqual(result, .sent(messageId: 70))
    }

    func testResultsStayWithTheirOwnMessage() async {
        let tracker = SendTracker()
        tracker.record(.sent(messageId: 11), for: 1)
        tracker.record(.sent(messageId: 22), for: 2)
        let second = await tracker.outcome(for: 2)
        let first = await tracker.outcome(for: 1)
        XCTAssertEqual(second, .sent(messageId: 22))
        XCTAssertEqual(first, .sent(messageId: 11))
    }

    func testFirstResultWins() async {
        let tracker = SendTracker()
        let failure = UploadError(kind: .transient, message: "later")
        tracker.record(.sent(messageId: 1), for: 3)
        tracker.record(.failed(failure), for: 3)
        let outcome = await tracker.outcome(for: 3)
        XCTAssertEqual(outcome, .sent(messageId: 1))
    }

    func testAbandonEndsAWaitAsCancelled() async {
        let tracker = SendTracker()
        async let outcome = tracker.outcome(for: 9)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(tracker.abandon(9))
        let result = await outcome
        guard case .failed(let error) = result else { return XCTFail("Expected a failure") }
        XCTAssertEqual(error.kind, .cancelled)
    }

    func testAbandonBeforeWaitingStillCancels() async {
        let tracker = SendTracker()
        XCTAssertTrue(tracker.abandon(4))
        let result = await tracker.outcome(for: 4)
        guard case .failed(let error) = result else { return XCTFail("Expected a failure") }
        XCTAssertEqual(error.kind, .cancelled)
    }

    func testLateResultAfterAbandonIsDropped() async {
        let tracker = SendTracker()
        tracker.abandon(6)
        tracker.record(.sent(messageId: 60), for: 6)
        // Nothing was kept, so the message can be abandoned again.
        XCTAssertTrue(tracker.abandon(6))
    }

    func testAbandonAfterResultKeepsTheResult() async {
        let tracker = SendTracker()
        tracker.record(.sent(messageId: 80), for: 8)
        XCTAssertFalse(tracker.abandon(8))
        let result = await tracker.outcome(for: 8)
        XCTAssertEqual(result, .sent(messageId: 80))
    }

    func testFailPendingEndsEveryWait() async {
        let tracker = SendTracker()
        async let outcome = tracker.outcome(for: 12)
        try? await Task.sleep(nanoseconds: 50_000_000)
        tracker.failPending(with: UploadError(kind: .authLost, message: "closed"))
        let result = await outcome
        XCTAssertEqual(result, .failed(UploadError(kind: .authLost, message: "closed")))
    }

    func testProgressIsReportedForWatchedFilesOnly() {
        let tracker = SendTracker()
        let reports = Reports()
        tracker.watchFile(id: 1, total: 100) { reports.add(sent: $0, total: $1) }
        tracker.fileUpdated(id: 2, uploadedSize: 50)
        tracker.fileUpdated(id: 1, uploadedSize: 40)
        XCTAssertEqual(reports.values, [Report(sent: 40, total: 100)])
    }

    func testProgressOnlyMovesForwardAndStaysWithinTheTotal() {
        let tracker = SendTracker()
        let reports = Reports()
        tracker.watchFile(id: 1, total: 100) { reports.add(sent: $0, total: $1) }
        tracker.fileUpdated(id: 1, uploadedSize: 30)
        tracker.fileUpdated(id: 1, uploadedSize: 30)
        tracker.fileUpdated(id: 1, uploadedSize: 20)
        tracker.fileUpdated(id: 1, uploadedSize: 130)
        XCTAssertEqual(reports.values, [Report(sent: 30, total: 100), Report(sent: 100, total: 100)])
    }

    func testProgressStopsAfterUnwatching() {
        let tracker = SendTracker()
        let reports = Reports()
        tracker.watchFile(id: 1, total: 100) { reports.add(sent: $0, total: $1) }
        tracker.unwatchFile(id: 1)
        tracker.fileUpdated(id: 1, uploadedSize: 50)
        XCTAssertTrue(reports.values.isEmpty)
    }

    // MARK: Destination

    @MainActor
    func testDestinationIsStoredAndCleared() throws {
        let suite = "test.destination.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = TelegramService(
            keychain: KeychainStore(service: "test.telegramupload.\(UUID().uuidString)"),
            logger: FileLogger(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            defaults: defaults,
            rootDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertNil(service.destinationChatId)

        service.setDestination(ChatSummary(id: -1_001_234_567_890, title: "Backup", kind: .channel))
        XCTAssertEqual(service.destinationChatId, -1_001_234_567_890)
        XCTAssertEqual(service.destinationTitle, "Backup")

        service.clearDestination()
        XCTAssertNil(service.destinationChatId)
        XCTAssertNil(service.destinationTitle)
    }

    @MainActor
    func testSendingWithoutLoginThrowsAuthLost() async throws {
        let service = TelegramService(
            keychain: KeychainStore(service: "test.telegramupload.\(UUID().uuidString)"),
            logger: FileLogger(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            rootDirectory: FileManager.default.temporaryDirectory
        )
        service.start()
        do {
            _ = try await service.sendDocument(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("none.jpg"),
                caption: Caption(text: "x"),
                progress: { _, _ in }
            )
            XCTFail("Expected an error")
        } catch let error as UploadError {
            XCTAssertEqual(error.kind, .authLost)
        }
    }
}

private struct Report: Equatable {
    let sent: Int64
    let total: Int64
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Report] = []

    var values: [Report] { lock.withLock { stored } }

    func add(sent: Int64, total: Int64) {
        lock.withLock { stored.append(Report(sent: sent, total: total)) }
    }
}
