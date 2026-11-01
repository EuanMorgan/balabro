import BalabroCore
import Foundation

/// The user's installed Balatro, the only source of the game's text and font.
/// The public repo ships neither.
public struct GameInstall: Sendable {
    public static let bundleID = "com.Balatro.localthunk"
    /// `Balatro.app` on the Mac, the folder holding `Balatro.exe` on Windows.
    let folder: URL

    public static func find() -> GameInstall? { Platform.findGame().map(GameInstall.init) }

    var archive: URL { Platform.gameArchive(in: folder) }

    /// Cached under `game/<archive mtime>/` in the data folder, so a game update re-extracts.
    public func extract(_ entry: String) async throws -> URL {
        let modified = try archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let cached = Platform.dataFolder
            .appending(path: "game/\(Int(modified.timeIntervalSince1970))")
            .appending(path: entry)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ZipArchive(file: archive).read(entry).write(to: cached, options: .atomic)
        return cached
    }

    public func loadText() async -> GameText {
        guard let url = try? await extract("localization/en-us.lua"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return .missing }
        return (try? GameText(enUSLua: source)) ?? .missing
    }
}

/// Steam's `steamapps/libraryfolders.vdf`, which lists every folder the user keeps games in.
public enum SteamLibraries {
    public static func paths(in vdf: String) -> [String] {
        vdf.matches(of: /"path"\s+"((?:[^"\\]|\\.)*)"/).map { String($0.1).replacing(#"\\"#, with: #"\"#) }
    }
}
