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
    static func find() -> GameInstall? { fatalError("not implemented") }

    var love: URL { app.appending(path: "Contents/Resources/Balatro.love") }

    /// `Balatro.love` is a zip. `/usr/bin/unzip -p <love> <entry>` ships with macOS, so we don't carry
    /// a zip reader. Cached under `Application Support/Balabro/game/<VERSION>/` keyed on the love file's mtime.
    func extract(_ entry: String) async throws -> URL { fatalError("not implemented") }

    func loadText() async -> GameText {
        // TODO: (try? GameText(enUSLua: String(contentsOf: extract("localization/en-us.lua")))) ?? .missing
        fatalError("not implemented")
    }

    /// Registers `resources/fonts/m6x11plus.ttf` for this process only
    /// (`CTFontManagerRegisterFontURLs(..., .process, ...)`). Returns false when the game isn't installed;
    /// `Theme.pixelFont` then falls back to SF Mono.
    @MainActor func registerFont() async -> Bool { fatalError("not implemented") }
}
