import BalabroCore
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Screenshot of the Balatro window, for the booster pack the save can't show.
enum GameWindow {
    /// The largest on-screen window owned by `GameInstall.bundleID`, captured with
    /// `SCScreenshotManager.captureImage`, downscaled so the long edge is at most 1568 px, as PNG.
    ///
    /// Returns nil when Screen Recording isn't granted or Balatro has no window. The first call
    /// triggers macOS's permission prompt. Ad-hoc signing means every new build counts as a new app
    /// to TCC, so users re-grant after each update.
    static func capturePNG() async -> Data? { fatalError("not implemented") }
}
