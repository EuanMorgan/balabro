import BalabroCore
import BalabroEngine
import Foundation
import Testing

@Suite
struct UpdateCheckTests {
    /// A data URL, so the check runs with no network.
    func feed(_ json: String) -> URL {
        URL(string: "data:application/json;base64,\(Data(json.utf8).base64EncodedString())")!
    }

    let releases = """
        [{"tag_name":"v0.3.0","draft":false,"prerelease":true,"html_url":"https://github.com/EuanMorgan/balabro/releases/tag/v0.3.0",
          "assets":[{"name":"Balabro-0.3.0-windows-x64.zip","browser_download_url":"https://github.com/EuanMorgan/balabro/releases/download/v0.3.0/Balabro-0.3.0-windows-x64.zip"}]},
         {"tag_name":"v0.2.0","draft":false,"prerelease":false,"html_url":"https://github.com/EuanMorgan/balabro/releases/tag/v0.2.0",
          "assets":[{"name":"Balabro-0.2.0.zip","browser_download_url":"https://github.com/EuanMorgan/balabro/releases/download/v0.2.0/Balabro-0.2.0.zip"}]}]
        """

    @Test func findsTheNewestReleaseWithThisAppsZip() async throws {
        let windows = await UpdateCheck(version: "0.1.0", asset: .windows, feed: feed(releases))?.newest()
        #expect(windows == AppRelease(
            version: AppVersion("0.3.0")!,
            download: URL(string: "https://github.com/EuanMorgan/balabro/releases/download/v0.3.0/Balabro-0.3.0-windows-x64.zip")!,
            page: URL(string: "https://github.com/EuanMorgan/balabro/releases/tag/v0.3.0")!))
        let mac = await UpdateCheck(version: "0.1.0", asset: .mac, feed: feed(releases))?.newest()
        #expect(mac?.download.absoluteString == "https://github.com/EuanMorgan/balabro/releases/download/v0.2.0/Balabro-0.2.0.zip")
    }

    @Test func aBuildFromSourceNeverChecks() {
        #expect(UpdateCheck(version: "dev", asset: .windows) == nil)
        #expect(UpdateCheck(version: "0.1.0", asset: .windows) != nil)
    }
}
