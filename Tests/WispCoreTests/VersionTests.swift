import Testing
@testable import WispCore

@Test func versionIsSet() {
    #expect(!Wisp.version.isEmpty)
}
