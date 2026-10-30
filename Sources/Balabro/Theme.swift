import AppKit
import SwiftUI

/// Balatro's palette, from `globals.lua:354-372` (the hex values only; no game assets).
/// Dark felt panel, chip blue and mult red as the only accents, nothing else competing.
enum Theme {
    static let felt = Color(hex: 0x374244)      // G.C.BLACK, the UI panel colour
    static let feltRaised = Color(hex: 0x4F6367) // G.C.L_BLACK
    static let feltDeep = Color(hex: 0x2C3536)   // darken(G.C.BLACK, 0.2), the game's inset boxes and shadows
    static let text = Color.white
    static let muted = Color(hex: 0xBFC7D5)      // G.C.JOKER_GREY
    static let chips = Color(hex: 0x009DFF)      // G.C.CHIPS
    static let chipsDeep = Color(hex: 0x006EB3)  // darken(G.C.CHIPS, 0.3), a button's lip
    static let mult = Color(hex: 0xFE5F55)       // G.C.MULT
    static let multDeep = Color(hex: 0xB2433C)   // darken(G.C.MULT, 0.3), a button's lip
    static let money = Color(hex: 0xF3B958)      // G.C.MONEY
    static let moneyDeep = Color(hex: 0xAA813E)  // darken(G.C.MONEY, 0.3)

    /// "m6x11plus" when `GameInstall.registerFont` succeeded, else SF Mono. Pixel fonts blur at
    /// fractional sizes, so sizes are whole multiples of the font's 11 px design size.
    static func pixelFont(_ multiple: Int) -> Font {
        hasPixelFont
            ? .custom(pixelFontName, fixedSize: CGFloat(11 * multiple))
            : .system(size: CGFloat(11 * multiple), weight: .semibold, design: .monospaced)
    }

    static var hasPixelFont: Bool { NSFont(name: pixelFontName, size: 11) != nil }
    private static let pixelFontName = "m6x11plus"

    /// Advice body text stays in the system font: long sentences read better there than in a pixel face.
    static let body = Font.system(size: 13)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
