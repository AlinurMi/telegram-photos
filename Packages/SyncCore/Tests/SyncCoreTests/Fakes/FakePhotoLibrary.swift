import Foundation

/// In-memory photo library: exports write a fixed number of bytes, and errors can be scripted per asset.
@testable import SyncCore

actor FakePhotoLibrary: PhotoLibrary {
    struct Export: Equatable {
        var assetLocalIdentifier: String
        var resourceKind: ResourceKind
        var fileURL: URL
    }

    var assets: [AssetDescriptor]
    var authorizationLevel: LibraryAuthorization
    var exportByteCount: Int
    var exportErrors: [String: UploadError] = [:]
    private(set) var exports: [Export] = []

    init(
        assets: [AssetDescriptor] = [],
        authorization: LibraryAuthorization = .full,
        exportByteCount: Int = 16
    ) {
        self.assets = assets
        self.authorizationLevel = authorization
        self.exportByteCount = exportByteCount
    }

    func setAssets(_ assets: [AssetDescriptor]) { self.assets = assets }
    func setAuthorization(_ level: LibraryAuthorization) { authorizationLevel = level }
    func setExportError(_ error: UploadError?, for identifier: String) { exportErrors[identifier] = error }

    func authorization() async -> LibraryAuthorization { authorizationLevel }

    func allAssets() async throws -> [AssetDescriptor] { assets }

    func export(assetLocalIdentifier: String, resourceKind: ResourceKind, to fileURL: URL) async throws {
        exports.append(
            Export(assetLocalIdentifier: assetLocalIdentifier, resourceKind: resourceKind, fileURL: fileURL))
        if let error = exportErrors[assetLocalIdentifier] { throw error }
        try Data(count: exportByteCount).write(to: fileURL)
    }
}
