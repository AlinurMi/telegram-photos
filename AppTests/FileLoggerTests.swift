import XCTest

@testable import TelegramPhotos

final class FileLoggerTests: XCTestCase {
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLoggerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWritesLinesInOrderWithLevelAndCategory() async throws {
        let logger = FileLogger(directory: directory, subsystem: "tests")
        logger.info("first", category: "sync")
        logger.error("second", category: "upload")
        await logger.flush()

        let urls = await logger.exportURLs()
        XCTAssertEqual(urls.map(\.lastPathComponent), ["app.log"])
        let lines = try String(contentsOf: urls[0], encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("[INFO] [sync] first"))
        XCTAssertTrue(lines[1].hasSuffix("[ERROR] [upload] second"))
    }

    func testRotatesAndKeepsOnlyOneOldFile() async throws {
        let logger = FileLogger(directory: directory, maxBytes: 200, subsystem: "tests")
        for index in 0..<30 {
            logger.info("line number \(index) with some padding text", category: "test")
        }
        await logger.flush()

        let urls = await logger.exportURLs()
        XCTAssertEqual(urls.map(\.lastPathComponent), ["app.log", "app.1.log"])
        let sizes = try urls.map { try Data(contentsOf: $0).count }
        XCTAssertTrue(sizes.allSatisfy { $0 <= 200 })
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(files), ["app.log", "app.1.log"])
    }

    func testExportURLsIsEmptyBeforeAnythingIsLogged() async {
        let logger = FileLogger(directory: directory, subsystem: "tests")
        let urls = await logger.exportURLs()
        XCTAssertTrue(urls.isEmpty)
    }
}
