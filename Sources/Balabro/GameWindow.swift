import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshot of the Balatro window, for the booster pack the save can't show.
enum GameWindow {
    /// The largest on-screen window owned by `GameInstall.bundleID` (or titled "Balatro", which also
    /// covers the game run under plain LÖVE), downscaled so the long edge is at most 1568 px, as PNG.
    ///
    /// Returns nil when Screen Recording isn't granted or Balatro has no window. The first call
    /// triggers macOS's permission prompt. Ad-hoc signing means every new build counts as a new app
    /// to TCC, so users re-grant after each update.
    static func capturePNG() async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows
                .filter({ $0.owningApplication?.bundleIdentifier == GameInstall.bundleID || $0.title == "Balatro" })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pixels = CGSize(width: window.frame.width * CGFloat(filter.pointPixelScale), height: window.frame.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, 1568 / max(pixels.width, pixels.height))
        let config = SCStreamConfiguration()
        config.width = Int(pixels.width * scale)
        config.height = Int(pixels.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }

        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }
}
