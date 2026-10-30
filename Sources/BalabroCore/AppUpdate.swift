import Foundation

/// A dotted version such as `0.1.4`. Release tags have a leading `v`, which is ignored.
public struct AppVersion: Sendable, Comparable, CustomStringConvertible {
    private let parts: [Int]

    public init?(_ text: String) {
        let digits = text.hasPrefix("v") ? text.dropFirst() : text[...]
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let length = max(a.parts.count, b.parts.count)
        return a.padded(to: length).lexicographicallyPrecedes(b.padded(to: length))
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    private func padded(to length: Int) -> [Int] { parts + Array(repeating: 0, count: length - parts.count) }
}

public struct AppRelease: Sendable, Equatable {
    public let version: AppVersion
    public let download: URL
    public let page: URL

    public init(version: AppVersion, download: URL, page: URL) { (self.version, self.download, self.page) = (version, download, page) }
}

public enum ReleaseFeed {
    /// The whole list, because `/releases/latest` leaves out pre-releases.
    public static let url = URL(string: "https://api.github.com/repos/EuanMorgan/balabro/releases?per_page=30")!

    /// The highest published version above `current` that has its zip attached.
    public static func newest(in json: Data, newerThan current: AppVersion) throws -> AppRelease? {
        try JSONDecoder().decode([GitHubRelease].self, from: json)
            .compactMap(\.appRelease)
            .filter { $0.version > current }
            .max { $0.version < $1.version }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let draft: Bool
        let html_url: URL
        let assets: [Asset]

        var appRelease: AppRelease? {
            guard !draft, let version = AppVersion(tag_name),
                  let zip = assets.first(where: { $0.name == "Balabro-\(version).zip" }) else { return nil }
            return AppRelease(version: version, download: zip.browser_download_url, page: html_url)
        }
    }
}
