import UIKit
import XCTest

@testable import TelegramPhotos

final class DocumentThumbnailTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "thumbnail-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeJPEG(width: Int, height: Int, named name: String) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let url = directory.appendingPathComponent(name)
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }

    func testPhotoGetsASmallJPEGPreview() async throws {
        let photo = try writeJPEG(width: 2000, height: 1000, named: "IMG_0001.JPG")

        let made = await DocumentThumbnail.make(for: photo, in: directory)
        let thumbnail = try XCTUnwrap(made)

        XCTAssertEqual(thumbnail.width, 320)
        XCTAssertEqual(thumbnail.height, 160)
        let size = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: thumbnail.url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, DocumentThumbnail.maximumBytes)
        XCTAssertEqual(thumbnail.url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
    }

    func testSmallPhotoIsNotEnlarged() async throws {
        let photo = try writeJPEG(width: 100, height: 80, named: "small.jpg")
        let made = await DocumentThumbnail.make(for: photo, in: directory)
        let thumbnail = try XCTUnwrap(made)
        XCTAssertLessThanOrEqual(thumbnail.width, 320)
        XCTAssertLessThanOrEqual(thumbnail.height, 320)
    }

    func testOtherFilesGetNoPreview() async throws {
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)
        let result = await DocumentThumbnail.make(for: notes, in: directory)
        XCTAssertNil(result)
    }

    func testUnreadableImageGetsNoPreview() async throws {
        let broken = directory.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: broken)
        let result = await DocumentThumbnail.make(for: broken, in: directory)
        XCTAssertNil(result)
    }
}
