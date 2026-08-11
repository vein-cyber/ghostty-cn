import Foundation
import Testing
@testable import Ghostty

struct AboutMetadataTests {
    @Test func releaseMetadata() {
        let metadata = AboutMetadata(
            infoDictionary: [
                "GhosttyCNVersion": "0.3.0-cn.1",
                "CFBundleVersion": "3000001",
                "GhosttyCommit": "0123456789abcdef0123456789abcdef01234567",
            ],
            upstreamVersion: "1.3.2"
        )

        #expect(metadata.productVersion == "0.3.0-cn.1")
        #expect(metadata.upstreamVersion == "1.3.2")
        #expect(metadata.build == "3000001")
        #expect(metadata.shortCommit == "012345678")
        #expect(metadata.versionURL?.absoluteString ==
            "https://github.com/vein-cyber/ghostty-cn/releases/tag/v0.3.0-cn.1")
        #expect(metadata.commitURL?.absoluteString ==
            "https://github.com/vein-cyber/ghostty-cn/commit/0123456789abcdef0123456789abcdef01234567")
    }

    @Test func developmentMetadataDoesNotLinkToARelease() {
        let metadata = AboutMetadata(
            infoDictionary: [
                "GhosttyCNVersion": "0.3.0-dev",
                "CFBundleVersion": "1",
                "GhosttyCommit": "",
            ],
            upstreamVersion: "1.3.2-dev"
        )

        #expect(metadata.productVersion == "0.3.0-dev")
        #expect(metadata.versionURL == nil)
        #expect(metadata.commit == nil)
        #expect(metadata.commitURL == nil)
    }

    @Test func missingProductVersionUsesDeveloperFallback() {
        let metadata = AboutMetadata(infoDictionary: [:], upstreamVersion: "1.3.2-dev")

        #expect(metadata.productVersion == "0.3.0-dev")
        #expect(metadata.build == nil)
    }
}
