import Foundation

/// Builds the short, stable hashtag-safe tag that identifies an asset in captions.
public enum AssetTag {
    /// Returns `"a"` plus the first 10 hex characters of the FNV-1a-64 hash of the identifier's UTF-8 bytes.
    public static func make(localIdentifier: String) -> String {
        let hash = fnv1a64(Array(localIdentifier.utf8))
        let hex = String(hash, radix: 16, uppercase: false)
        let padded = String(repeating: "0", count: 16 - hex.count) + hex
        return "a" + padded.prefix(10)
    }

    /// Computes the 64-bit FNV-1a hash of the given bytes.
    public static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
