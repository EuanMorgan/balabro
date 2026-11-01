import BalabroCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How both apps find a newer Balabro on GitHub. Each installs it in its own way.
public struct UpdateCheck: Sendable {
    let current: AppVersion
    let asset: ReleaseAsset
    let feed: URL

    /// nil for a build from source, whose version is "dev".
    public init?(version: String, asset: ReleaseAsset, feed: URL = ReleaseFeed.url) {
        guard let current = AppVersion(version) else { return nil }
        (self.current, self.asset, self.feed) = (current, asset, feed)
    }

    public static let thisApp = UpdateCheck(version: Platform.version, asset: Platform.releaseAsset)

    /// nil when nothing newer has this platform's zip. Being offline or rate limited is nil too, and the next check tries again.
    public func newest() async -> AppRelease? {
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData)
        guard let (json, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? ReleaseFeed.newest(in: json, newerThan: current, asset: asset)
    }

    /// Checks at once and then every 6 hours, until cancelled.
    public func watch(_ found: @MainActor (AppRelease) -> Void) async {
        while !Task.isCancelled {
            if let release = await newest() { await found(release) }
            try? await Task.sleep(for: .seconds(6 * 60 * 60))
        }
    }
}
