import Foundation

/// Whether an asset is a photo or a video.
public enum MediaKind: String, Codable, Sendable { case image, video }

/// The kind of a file stored inside a photo-library asset.
public enum ResourceKind: String, Codable, Sendable {
    case photo, fullSizePhoto, alternatePhoto, pairedVideo, fullSizePairedVideo, video, fullSizeVideo
}

/// One file belonging to an asset, as reported by the photo library.
public struct ResourceDescriptor: Codable, Sendable, Equatable {
    public var kind: ResourceKind
    public var originalFilename: String
    public var byteSize: Int64?

    /// Creates a resource descriptor; `byteSize` is nil when unknown.
    public init(kind: ResourceKind, originalFilename: String, byteSize: Int64? = nil) {
        self.kind = kind
        self.originalFilename = originalFilename
        self.byteSize = byteSize
    }
}

/// A GPS position in degrees.
public struct Coordinate: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    /// Creates a coordinate from latitude and longitude in degrees.
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Everything SyncCore needs to know about one photo-library asset.
public struct AssetDescriptor: Codable, Sendable, Equatable {
    public var localIdentifier: String
    public var creationDate: Date?
    public var modificationDate: Date?
    public var mediaKind: MediaKind
    public var isScreenshotOrRecording: Bool
    public var location: Coordinate?
    public var resources: [ResourceDescriptor]

    /// Creates an asset descriptor.
    public init(
        localIdentifier: String,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        mediaKind: MediaKind,
        isScreenshotOrRecording: Bool = false,
        location: Coordinate? = nil,
        resources: [ResourceDescriptor] = []
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.mediaKind = mediaKind
        self.isScreenshotOrRecording = isScreenshotOrRecording
        self.location = location
        self.resources = resources
    }
}
