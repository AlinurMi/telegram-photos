import Photos

import SyncCore

import XCTest

@testable import TelegramPhotos

final class PhotoKitLibraryTests: XCTestCase {
    func testAuthorizationMapping() {
        XCTAssertEqual(PhotoKitLibrary.authorization(from: .authorized), .full)
        XCTAssertEqual(PhotoKitLibrary.authorization(from: .limited), .limited)
        XCTAssertEqual(PhotoKitLibrary.authorization(from: .denied), .denied)
        XCTAssertEqual(PhotoKitLibrary.authorization(from: .restricted), .denied)
        XCTAssertEqual(PhotoKitLibrary.authorization(from: .notDetermined), .notDetermined)
    }

    func testResourceKindMapping() {
        XCTAssertEqual(PhotoKitLibrary.resourceKind(for: .photo), .photo)
        XCTAssertEqual(PhotoKitLibrary.resourceKind(for: .fullSizePhoto), .fullSizePhoto)
        XCTAssertEqual(PhotoKitLibrary.resourceKind(for: .alternatePhoto), .alternatePhoto)
        XCTAssertEqual(PhotoKitLibrary.resourceKind(for: .pairedVideo), .pairedVideo)
        XCTAssertEqual(PhotoKitLibrary.resourceKind(for: .fullSizePairedVideo), .fullSizePairedVideo)
        XCTAssertEqual(PhotoKitLibrary.resourceKind(for: .video), .video)
        XCTAssertEqual(PhotoKitLibrary.resourceKind(for: .fullSizeVideo), .fullSizeVideo)
    }

    func testIgnoredResourceTypes() {
        XCTAssertNil(PhotoKitLibrary.resourceKind(for: .audio))
        XCTAssertNil(PhotoKitLibrary.resourceKind(for: .adjustmentData))
        XCTAssertNil(PhotoKitLibrary.resourceKind(for: .adjustmentBasePhoto))
    }

    func testNetworkErrorsMeanNotLocal() {
        for code in [PHPhotosError.Code.networkAccessRequired, .networkError] {
            let error = PhotoKitLibrary.uploadError(domain: PHPhotosErrorDomain, code: code.rawValue)
            XCTAssertEqual(error.kind, .notLocal)
        }
    }

    func testMissingAssetIsPermanent() {
        let error = PhotoKitLibrary.uploadError(
            domain: PHPhotosErrorDomain, code: PHPhotosError.Code.identifierNotFound.rawValue)
        XCTAssertEqual(error.kind, .permanent)
    }

    func testCancellationMapping() {
        XCTAssertEqual(PhotoKitLibrary.uploadError(for: CancellationError()).kind, .cancelled)
        let cancelled = PhotoKitLibrary.uploadError(
            domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue)
        XCTAssertEqual(cancelled.kind, .cancelled)
    }

    func testOtherErrorsAreTransient() {
        XCTAssertEqual(
            PhotoKitLibrary.uploadError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.internalError.rawValue)
                .kind, .transient)
        XCTAssertEqual(PhotoKitLibrary.uploadError(domain: NSCocoaErrorDomain, code: 4).kind, .transient)
    }
}
