import Foundation

/// One file that should be uploaded for an asset, before it becomes an `UploadUnit`.
public struct PlannedUnit: Sendable, Equatable {
    public var role: UnitRole
    public var resourceKind: ResourceKind
    public var uploadFilename: String
    public var byteSize: Int64?

    /// Creates a planned unit; `byteSize` is nil when unknown.
    public init(role: UnitRole, resourceKind: ResourceKind, uploadFilename: String, byteSize: Int64? = nil) {
        self.role = role
        self.resourceKind = resourceKind
        self.uploadFilename = uploadFilename
        self.byteSize = byteSize
    }
}

/// Decides which files to upload for an asset and what to call them.
public enum ResourcePlanner {
    /// Returns the units to upload, ordered primary, then RAW, then Live Photo video; empty if there is nothing usable.
    public static func plan(_ asset: AssetDescriptor) -> [PlannedUnit] {
        let originalName = originalName(of: asset)
        let base = split(originalName).base

        let primaryOriginal: ResourceKind = asset.mediaKind == .image ? .photo : .video
        let primaryEdited: ResourceKind = asset.mediaKind == .image ? .fullSizePhoto : .fullSizeVideo

        var units: [PlannedUnit] = []
        if let edited = first(of: primaryEdited, in: asset) {
            units.append(
                PlannedUnit(
                    role: .primary, resourceKind: edited.kind,
                    uploadFilename: editedName(base: base, source: edited.originalFilename),
                    byteSize: edited.byteSize))
        } else if let original = first(of: primaryOriginal, in: asset) {
            units.append(
                PlannedUnit(
                    role: .primary, resourceKind: original.kind,
                    uploadFilename: original.originalFilename.isEmpty ? originalName : original.originalFilename,
                    byteSize: original.byteSize))
        }
        guard !units.isEmpty, asset.mediaKind == .image else { return units }

        if let raw = first(of: .alternatePhoto, in: asset) {
            units.append(
                PlannedUnit(
                    role: .raw, resourceKind: raw.kind, uploadFilename: raw.originalFilename, byteSize: raw.byteSize))
        }
        if let editedLive = first(of: .fullSizePairedVideo, in: asset) {
            units.append(
                PlannedUnit(
                    role: .live, resourceKind: editedLive.kind,
                    uploadFilename: editedName(base: base, source: editedLive.originalFilename),
                    byteSize: editedLive.byteSize))
        } else if let live = first(of: .pairedVideo, in: asset) {
            units.append(
                PlannedUnit(
                    role: .live, resourceKind: live.kind,
                    uploadFilename: plainName(base: base, source: live.originalFilename),
                    byteSize: live.byteSize))
        }
        return units
    }

    private static func first(of kind: ResourceKind, in asset: AssetDescriptor) -> ResourceDescriptor? {
        asset.resources.first { $0.kind == kind }
    }

    /// The photo's (or video's) own filename, falling back to the first named resource, then `"asset"`.
    private static func originalName(of asset: AssetDescriptor) -> String {
        let primaryKind: ResourceKind = asset.mediaKind == .image ? .photo : .video
        if let name = first(of: primaryKind, in: asset)?.originalFilename, !name.isEmpty {
            return name
        }
        return asset.resources.first { !$0.originalFilename.isEmpty }?.originalFilename ?? "asset"
    }

    private static func editedName(base: String, source: String) -> String {
        let ext = split(source).ext
        return ext.isEmpty ? "\(base)_edited" : "\(base)_edited.\(ext.uppercased())"
    }

    private static func plainName(base: String, source: String) -> String {
        let ext = split(source).ext
        return ext.isEmpty ? base : "\(base).\(ext.uppercased())"
    }

    /// Splits at the last dot; a leading dot or trailing dot does not count as an extension separator.
    private static func split(_ filename: String) -> (base: String, ext: String) {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex,
            filename.index(after: dot) != filename.endIndex
        else { return (filename, "") }
        return (String(filename[..<dot]), String(filename[filename.index(after: dot)...]))
    }
}
