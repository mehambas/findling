import XCTest
@testable import FindlingCore

final class ReleaseTests: XCTestCase {
    private func version(_ text: String) throws -> AppVersion { try XCTUnwrap(AppVersion(text), text) }

    func testVersionsCompareByNumber() throws {
        XCTAssertGreaterThan(try version("0.10.0"), try version("0.9.0"))
        XCTAssertGreaterThan(try version("v0.2.0"), try version("0.1.0"))
        XCTAssertGreaterThan(try version("1.0.0"), try version("0.99.99"))
        XCTAssertGreaterThan(try version("0.1.1"), try version("0.1"))
        XCTAssertEqual(try version("v0.2.0"), try version("0.2.0"))
        XCTAssertEqual(try version("1.0"), try version("1.0.0"))
        XCTAssertFalse(try version("0.1.0") > version("0.1.0"))
        XCTAssertEqual(try version("v0.2.0").description, "0.2.0")
        XCTAssertEqual(try version(" 0.3.0\n").description, "0.3.0")
    }

    func testPrereleasesComeBeforeTheirRelease() throws {
        XCTAssertLessThan(try version("1.0.0-beta.2"), try version("1.0.0"))
        XCTAssertLessThan(try version("1.0.0-beta.2"), try version("1.0.0-beta.10"))
        XCTAssertGreaterThan(try version("1.0.1-beta"), try version("1.0.0"))
        XCTAssertEqual(try version("1.0.0+5"), try version("1.0.0"), "Build metadata does not count")
    }

    func testNonVersionsAreRejected() {
        for text in ["", "v", "latest", "1..0", "1.0.", ".1", "1.0.0-", "release-1.0", "1.0 beta", "vv1.0"] {
            XCTAssertNil(AppVersion(text), text)
        }
    }

    func testParsesGitHubLatestRelease() throws {
        let json = """
        {
          "url": "https://api.github.com/repos/mehambas/findling/releases/1",
          "html_url": "https://github.com/mehambas/findling/releases/tag/v0.2.0",
          "tag_name": "v0.2.0",
          "name": "Findling 0.2.0",
          "draft": false,
          "prerelease": false,
          "body": "- Update check",
          "assets": [
            {"name": "Findling.dmg", "size": 4961805, "content_type": "application/x-apple-diskimage",
             "browser_download_url": "https://github.com/mehambas/findling/releases/download/v0.2.0/Findling.dmg"},
            {"name": "Findling.dmg.sha256", "size": 78,
             "browser_download_url": "https://github.com/mehambas/findling/releases/download/v0.2.0/Findling.dmg.sha256"}
          ]
        }
        """
        let release = try Release.parse(Data(json.utf8))
        XCTAssertEqual(release.tag, "v0.2.0")
        XCTAssertEqual(release.version, try version("0.2.0"))
        XCTAssertEqual(release.page.absoluteString, "https://github.com/mehambas/findling/releases/tag/v0.2.0")
        XCTAssertEqual(release.assets.count, 2)
        XCTAssertEqual(release.assets["Findling.dmg"]?.absoluteString, "https://github.com/mehambas/findling/releases/download/v0.2.0/Findling.dmg")
        XCTAssertEqual(release.assets["Findling.dmg.sha256"]?.lastPathComponent, "Findling.dmg.sha256")
        let stored = try JSONDecoder().decode(Release.self, from: JSONEncoder().encode(release))
        XCTAssertEqual(stored, release, "The offer is kept across launches")
    }

    func testRejectsUnusableReleaseAnswers() {
        XCTAssertNoThrow(try Release.parse(Data(#"{"tag_name": "v1.0.0", "html_url": "https://example.com", "assets": []}"#.utf8)))
        XCTAssertThrowsError(try Release.parse(Data(#"{"message": "Not Found", "documentation_url": "https://docs.github.com"}"#.utf8)))
        XCTAssertThrowsError(try Release.parse(Data(#"{"tag_name": "nightly", "html_url": "https://example.com", "assets": []}"#.utf8)))
        XCTAssertThrowsError(try Release.parse(Data("<html>rate limited</html>".utf8)))
    }

    func testChecksumFiles() {
        let digest = "3f786850e387550fdab836ed7e6dc881de23001b6ebd1b5b6c9e0a2c0b4c4f42"
        XCTAssertEqual(Release.digest(inChecksumFile: digest), digest)
        XCTAssertEqual(Release.digest(inChecksumFile: digest + "  Findling.dmg\n"), digest)
        XCTAssertEqual(Release.digest(inChecksumFile: digest + " *dist/Findling.dmg"), digest, "shasum's binary mode marker")
        XCTAssertEqual(Release.digest(inChecksumFile: digest.uppercased() + "\n"), digest)
        XCTAssertEqual(Release.digest(inChecksumFile: "\n  " + digest + "\tFindling.dmg"), digest)
        XCTAssertNil(Release.digest(inChecksumFile: ""))
        XCTAssertNil(Release.digest(inChecksumFile: String(digest.dropLast())), "Too short")
        XCTAssertNil(Release.digest(inChecksumFile: digest + "0"), "Too long")
        XCTAssertNil(Release.digest(inChecksumFile: String(digest.dropLast()) + "g"), "Not hex")
        XCTAssertNil(Release.digest(inChecksumFile: "Findling.dmg  " + digest), "The name comes after the digest")
        XCTAssertNil(Release.digest(inChecksumFile: "<!DOCTYPE html><html>Not Found</html>"))
    }
}
