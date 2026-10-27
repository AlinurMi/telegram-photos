import Testing

@testable import SyncCore

@Test func versionIsSet() { #expect(!SyncCoreInfo.version.isEmpty) }
