import BalabroCore
import Foundation
import Testing

@Suite
struct AppUpdateTests {
    func release(_ tag: String, draft: Bool = false, assets: [String]? = nil) -> String {
        let names = assets ?? ["Balabro-\(tag.dropFirst()).zip"]
        let list = names.map { #"{"name":"\#($0)","browser_download_url":"https://github.com/o/r/releases/download/\#(tag)/\#($0)"}"# }
        return """
            {"tag_name":"\(tag)","draft":\(draft),"prerelease":true,"html_url":"https://github.com/o/r/releases/tag/\(tag)",
             "assets":[\(list.joined(separator: ","))]}
            """
    }

    func newest(_ releases: [String], than current: String, for asset: ReleaseAsset = .mac) throws -> AppRelease? {
        try ReleaseFeed.newest(in: Data("[\(releases.joined(separator: ","))]".utf8), newerThan: AppVersion(current)!, asset: asset)
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
            release("v0.2.5", assets: ["notes.txt"]),
            release("v0.2.0"),
        ], than: "0.1.4")
        #expect(found?.version.description == "0.2.0")
    }

    @Test func eachAppTakesOnlyItsOwnZip() throws {
        let releases = [
            release("v0.4.0", assets: ["Balabro-0.4.0-windows-x64.zip"]),
            release("v0.3.0", assets: ["Balabro-0.3.0.zip"]),
            release("v0.2.0", assets: ["Balabro-0.2.0.zip", "Balabro-0.2.0-windows-x64.zip"]),
        ]
        #expect(try newest(releases, than: "0.1.0", for: .mac)?.download.absoluteString == "https://github.com/o/r/releases/download/v0.3.0/Balabro-0.3.0.zip")
        #expect(try newest(releases, than: "0.1.0", for: .windows)?.download.absoluteString == "https://github.com/o/r/releases/download/v0.4.0/Balabro-0.4.0-windows-x64.zip")
        #expect(try newest(releases, than: "0.3.0", for: .mac) == nil)
        #expect(try newest(Array(releases.dropFirst()), than: "0.1.0", for: .windows)?.download.absoluteString == "https://github.com/o/r/releases/download/v0.2.0/Balabro-0.2.0-windows-x64.zip")
    }

    @Test func skipsTagsThatAreNotVersions() throws {
        #expect(try newest([release("vnext")], than: "0.1.4") == nil)
    }

    @Test func aResponseThatIsNotAListThrows() {
        #expect(throws: (any Error).self) {
            try ReleaseFeed.newest(in: Data(#"{"message":"API rate limit exceeded"}"#.utf8), newerThan: AppVersion("0.1.4")!, asset: .mac)
        }
    }
}
