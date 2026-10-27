// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SyncCore",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [.library(name: "SyncCore", targets: ["SyncCore"])],
    targets: [
        .target(name: "SyncCore"),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"]),
    ],
    swiftLanguageModes: [.v5]
)
