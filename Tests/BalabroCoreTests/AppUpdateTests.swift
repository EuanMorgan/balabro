import BalabroCore
import Foundation
import Testing

@Suite
struct AppUpdateTests {
    func release(_ tag: String, draft: Bool = false, asset: String? = nil) -> String {
        let name = asset ?? "Balabro-\(tag.dropFirst()).zip"
        return """
            {"tag_name":"\(tag)","draft":\(draft),"prerelease":true,"html_url":"https://github.com/o/r/releases/tag/\(tag)",
             "assets":[{"name":"\(name)","browser_download_url":"https://github.com/o/r/releases/download/\(tag)/\(name)"}]}
            """
    }

    func newest(_ releases: [String], than current: String) throws -> AppRelease? {
        try ReleaseFeed.newest(in: Data("[\(releases.joined(separator: ","))]".utf8), newerThan: AppVersion(current)!)
    }

    @Test func picksTheHighestNewerRelease() throws {
        let found = try newest([release("v0.1.5"), release("v0.2.0"), release("v0.1.9")], than: "0.1.4")
        #expect(found?.version.description == "0.2.0")
        #expect(found?.download.absoluteString == "https://github.com/o/r/releases/download/v0.2.0/Balabro-0.2.0.zip")
        #expect(found?.page.absoluteString == "https://github.com/o/r/releases/tag/v0.2.0")
    }

    @Test func comparesVersionsAsNumbersNotText() throws {
        #expect(try newest([release("v0.10.0")], than: "0.9.0")?.version.description == "0.10.0")
        #expect(try newest([release("v0.9.0")], than: "0.10.0") == nil)
    }

    @Test func offersNothingWhenAlreadyCurrentOrAhead() throws {
        #expect(try newest([release("v0.1.4")], than: "0.1.4") == nil)
        #expect(try newest([release("v0.1.0")], than: "0.1.4") == nil)
        #expect(try newest([release("v0.2")], than: "0.2.0") == nil)
    }

    @Test func skipsDraftsAndReleasesWithoutTheZip() throws {
        let found = try newest([
            release("v0.3.0", draft: true),
            release("v0.2.5", asset: "notes.txt"),
            release("v0.2.0"),
        ], than: "0.1.4")
        #expect(found?.version.description == "0.2.0")
    }

    @Test func skipsTagsThatAreNotVersions() throws {
        #expect(try newest([release("vnext")], than: "0.1.4") == nil)
    }

    @Test func aResponseThatIsNotAListThrows() {
        #expect(throws: (any Error).self) {
            try ReleaseFeed.newest(in: Data(#"{"message":"API rate limit exceeded"}"#.utf8), newerThan: AppVersion("0.1.4")!)
        }
    }
}
