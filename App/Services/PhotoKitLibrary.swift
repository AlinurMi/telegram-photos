import CoreLocation

import Foundation

import Photos

/// Reads the photo library through PhotoKit and exports original files for upload.
///
/// Only the user's own library is read (no iCloud Shared Albums, no hidden items),
/// and files that aren't stored on the device are never downloaded.
import SyncCore

struct PhotoKitLibrary: PhotoLibrary {
    private let logger: FileLogger

    init(logger: FileLogger = .shared) {
        self.logger = logger
    }

    func authorization() async -> LibraryAuthorization {
        Self.authorization(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Shows the system permission prompt if needed and returns the resulting level.
    func requestAuthorization() async -> LibraryAuthorization {
        Self.authorization(from: await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func allAssets() async throws -> [AssetDescriptor] {
        let options = Self.fetchOptions(includeAllBurstAssets: false)
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let fetched = PHAsset.fetchAssets(with: options)

        var assets: [PHAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }

        var seen = Set<String>()
        var result: [AssetDescriptor] = []
        result.reserveCapacity(assets.count)

        for asset in assets {
            try Task.checkCancellation()
            if seen.insert(asset.localIdentifier).inserted, let descriptor = Self.descriptor(for: asset) {
                result.append(descriptor)
            }
            guard asset.representsBurst, let burstId = asset.burstIdentifier else { continue }
            for frame in Self.userPickedFrames(burstIdentifier: burstId)
            where seen.insert(frame.localIdentifier).inserted {
                if let descriptor = Self.descriptor(for: frame) {
                    result.append(descriptor)
                }
            }
        }
        return result
    }

    func export(assetLocalIdentifier: String, resourceKind: ResourceKind, to fileURL: URL) async throws {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [assetLocalIdentifier], options: nil)
        guard let asset = fetched.firstObject else {
            throw UploadError(kind: .permanent, message: "asset deleted")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { Self.resourceKind(for: $0.type) == resourceKind }) else {
            throw UploadError(kind: .permanent, message: "resource not found")
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        // The manager fails if something is already at the destination.
        try? FileManager.default.removeItem(at: fileURL)

        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: fileURL, options: options)
        } catch {
            let nsError = error as NSError
            logger.warning(
                "export failed for \(assetLocalIdentifier) \(resourceKind.rawValue): \(nsError.domain) \(nsError.code)",
                category: "photos"
            )
            throw Self.uploadError(for: error)
        }
    }

    // MARK: - Pure mappings (unit tested)

    static func authorization(from status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Returns `nil` for resource types the app never uploads (audio, adjustment data, proxies).
    static func resourceKind(for type: PHAssetResourceType) -> ResourceKind? {
        switch type {
        case .photo: return .photo
        case .fullSizePhoto: return .fullSizePhoto
        case .alternatePhoto: return .alternatePhoto
        case .pairedVideo: return .pairedVideo
        case .fullSizePairedVideo: return .fullSizePairedVideo
        case .video: return .video
        case .fullSizeVideo: return .fullSizeVideo
        default: return nil
        }
    }

    /// Network access is always off for exports, so a network-related Photos error means the file isn't on the device.
    static func uploadError(for error: Error) -> UploadError {
        if error is CancellationError {
            return UploadError(kind: .cancelled, message: "cancelled")
        }
        let nsError = error as NSError
        return uploadError(domain: nsError.domain, code: nsError.code)
    }

    static func uploadError(domain: String, code: Int) -> UploadError {
        guard domain == PHPhotosErrorDomain else {
            return UploadError(kind: .transient, message: "export failed (\(domain) \(code))")
        }
        switch PHPhotosError.Code(rawValue: code) {
        case .networkAccessRequired, .networkError:
            return UploadError(kind: .notLocal, message: "not stored on this device")
        case .identifierNotFound:
            return UploadError(kind: .permanent, message: "asset deleted")
        case .userCancelled:
            return UploadError(kind: .cancelled, message: "cancelled")
        default:
            return UploadError(kind: .transient, message: "export failed (\(domain) \(code))")
        }
    }

    // MARK: - PhotoKit helpers

    private static func fetchOptions(includeAllBurstAssets: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = includeAllBurstAssets
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    private static func userPickedFrames(burstIdentifier: String) -> [PHAsset] {
        let fetched = PHAsset.fetchAssets(
            withBurstIdentifier: burstIdentifier,
            options: fetchOptions(includeAllBurstAssets: true)
        )
        var frames: [PHAsset] = []
        fetched.enumerateObjects { frame, _, _ in
            if frame.burstSelectionTypes.contains(.userPick) {
                frames.append(frame)
            }
        }
        return frames
    }

    private static func descriptor(for asset: PHAsset) -> AssetDescriptor? {
        let mediaKind: MediaKind
        switch asset.mediaType {
        case .image: mediaKind = .image
        case .video: mediaKind = .video
        default: return nil
        }

        let resources = PHAssetResource.assetResources(for: asset).compactMap { resource -> ResourceDescriptor? in
            guard let kind = resourceKind(for: resource.type) else { return nil }
            // "fileSize" is an undocumented key, so a missing value just means the size is unknown.
            let size = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
            return ResourceDescriptor(kind: kind, originalFilename: resource.originalFilename, byteSize: size)
        }

        var location: Coordinate?
        if let coordinate = asset.location?.coordinate, CLLocationCoordinate2DIsValid(coordinate) {
            location = Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }

        let isScreenshotOrRecording =
            asset.mediaSubtypes.contains(.photoScreenshot) || asset.mediaSubtypes.contains(.videoScreenRecording)

        return AssetDescriptor(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            mediaKind: mediaKind,
            isScreenshotOrRecording: isScreenshotOrRecording,
            location: location,
            resources: resources
        )
    }
}
