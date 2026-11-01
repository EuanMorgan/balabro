import AppKit
import BalabroCore
import CoreText
import Foundation

/// The user's installed Balatro, the only source of the game's text and font.
/// The public repo ships neither.
struct GameInstall: Sendable {
    static let bundleID = "com.Balatro.localthunk"
    let app: URL

    /// The Steam path first, then Launch Services by bundle ID (other Steam libraries, a moved app).
    static func find() -> GameInstall? {
        let steam = URL.applicationSupportDirectory.appending(path: "Steam/steamapps/common/Balatro/Balatro.app")
        let app = FileManager.default.fileExists(atPath: steam.path)
            ? steam : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return app.map(GameInstall.init)
    }

    var love: URL { app.appending(path: "Contents/Resources/Balatro.love") }

    /// Cached under `Application Support/Balabro/game/<love mtime>/`, so a game update re-extracts.
    func extract(_ entry: String) async throws -> URL {
        let modified = try love.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let cached = URL.applicationSupportDirectory
            .appending(path: "Balabro/game/\(Int(modified.timeIntervalSince1970))")
            .appending(path: entry)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ZipArchive(file: love).read(entry).write(to: cached, options: .atomic)
        return cached
    }

    func loadText() async -> GameText {
        guard let url = try? await extract("localization/en-us.lua"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return .missing }
        return (try? GameText(enUSLua: source)) ?? .missing
    }

    /// Registers `resources/fonts/m6x11plus.ttf` for this process only. Returns false when the game
    /// isn't installed; `Theme.pixelFont` then falls back to SF Mono.
    @MainActor func registerFont() async -> Bool {
        guard let url = try? await extract("resources/fonts/m6x11plus.ttf") else { return false }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return Theme.hasPixelFont
    }
}
