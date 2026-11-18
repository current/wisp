import Foundation
import Testing
@testable import WispCore

@Test func releaseComparesDottedNumbers() {
    #expect(Release.isNewer("0.3.0", than: "0.2.0"))
    #expect(Release.isNewer("0.10.0", than: "0.9.1"))
    #expect(Release.isNewer("1.0", than: "0.9.9"))
    #expect(!Release.isNewer("0.2.0", than: "0.2.0"))
    #expect(!Release.isNewer("0.2", than: "0.2.0"))
    #expect(!Release.isNewer("0.1.9", than: "0.2.0"))
}

@Test func releaseReadsGitHubsAnswer() {
    let json = #"{"tag_name":"v0.3.0","html_url":"https://github.com/current/wisp/releases/tag/v0.3.0","name":"Wisp 0.3.0"}"#
    let release = Release.parse(Data(json.utf8))
    #expect(release?.version == "0.3.0")
    #expect(release?.page.absoluteString == "https://github.com/current/wisp/releases/tag/v0.3.0")
    #expect(Release.parse(Data("{}".utf8)) == nil)
}
