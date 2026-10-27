import Foundation
import Testing

@testable import SyncCore

private func makeTempFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fake-\(UUID().uuidString).bin")
    try Data(count: bytes).write(to: url)
    return url
}
@Suite struct FakesTests {
    @Test func photoLibraryExportsBytesAndRecordsCalls() async throws {
        let library = FakePhotoLibrary(exportByteCount: 32)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try await library.export(assetLocalIdentifier: "A", resourceKind: .photo, to: url)
        #expect(try Data(contentsOf: url).count == 32)
        #expect(await library.exports.count == 1)
    }

    @Test func photoLibraryThrowsScriptedErrors() async throws {
        let library = FakePhotoLibrary()
        let error = UploadError(kind: .notLocal, message: "iCloud")
        await library.setExportError(error, for: "A")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString).bin")
        await #expect(throws: UploadError.self) {
            try await library.export(assetLocalIdentifier: "A", resourceKind: .photo, to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func uploaderRecordsSendsAndPlaysBackScriptedResults() async throws {
        let uploader = FakeUploader()
        let url = try makeTempFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        await uploader.script(send: .failure(UploadError(kind: .transient, message: "boom")))
        await #expect(throws: UploadError.self) {
            _ = try await uploader.sendDocument(fileURL: url, caption: Caption(text: "x"), progress: { _, _ in })
        }
        let first = try await uploader.sendDocument(fileURL: url, caption: Caption(text: "y"), progress: { _, _ in })
        let second = try await uploader.sendDocument(fileURL: url, caption: Caption(text: "z"), progress: { _, _ in })
        #expect(second == first + 1)
        let sent = await uploader.sent
        #expect(sent.map(\.caption.text) == ["x", "y", "z"])
        #expect(sent.allSatisfy { $0.byteCount == 10 })
    }

    @Test func uploaderFindMessageIsScriptedAndDefaultsToNil() async throws {
        let uploader = FakeUploader()
        #expect(try await uploader.findMessage(assetTag: "a1", role: .primary) == nil)
        await uploader.script(find: .success(7))
        #expect(try await uploader.findMessage(assetTag: "a1", role: .primary) == 7)
    }

    @Test func uploaderStreamsCaptionsInOrderThenFinishes() async throws {
        let uploader = FakeUploader(captions: ["one", "two"])
        var seen: [String] = []
        for try await caption in uploader.allDocumentCaptions() { seen.append(caption) }
        #expect(seen == ["one", "two"])
    }

    @Test func uploaderStreamCanFailAfterItsCaptions() async throws {
        let uploader = FakeUploader(captions: ["one"])
        await uploader.setCaptionsError(UploadError(kind: .transient, message: "net"))
        var seen: [String] = []
        await #expect(throws: UploadError.self) {
            for try await caption in uploader.allDocumentCaptions() { seen.append(caption) }
        }
        #expect(seen == ["one"])
    }

    @Test func environmentIsMutable() async {
        let environment = FakeEnvironment()
        #expect(await environment.networkState() == .ok)
        await environment.setNetwork(.expensive)
        await environment.setCharging(false)
        await environment.setFreeDisk(5)
        #expect(await environment.networkState() == .expensive)
        #expect(await environment.isCharging() == false)
        #expect(await environment.freeDiskBytes() == 5)
    }

    @Test func placeResolverReturnsScriptedNamesAndCountsLookups() async {
        let resolver = FakePlaceResolver()
        let here = Coordinate(latitude: 1, longitude: 2)
        await resolver.setName("Somewhere", for: here)
        #expect(await resolver.placeName(for: here) == "Somewhere")
        #expect(await resolver.placeName(for: Coordinate(latitude: 3, longitude: 4)) == nil)
        #expect(await resolver.lookups == 2)
    }

    @Test func fixedClockOnlyMovesWhenAdvanced() {
        let start = Date(timeIntervalSince1970: 1000)
        let clock = FixedClock(start)
        #expect(clock.now() == start)
        clock.advance(by: 60)
        #expect(clock.now() == start.addingTimeInterval(60))
    }

    @Test func observerRecordsEventsInOrder() async {
        let observer = RecordingObserver()
        await observer.handle(.runStarted(total: 2, totalBytes: 10))
        await observer.handle(.unitProgress(sent: 1, total: 2))
        #expect(await observer.events == [.runStarted(total: 2, totalBytes: 10), .unitProgress(sent: 1, total: 2)])
    }
}
