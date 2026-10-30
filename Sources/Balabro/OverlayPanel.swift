import AppKit
import SwiftUI

/// The always-on-top coaching panel.
///
/// - `.nonactivatingPanel`: clicking it doesn't activate Balabro, so Balatro keeps focus and stays fullscreen.
/// - `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` plus the app's
///   `.accessory` policy let it show on Balatro's fullscreen Space.
/// - `level = .screenSaver`: LÖVE's SDL backend can raise a fullscreen window above `.floating`;
///   `.screenSaver` sits above it without covering system alerts.
/// - `isMovableByWindowBackground` and `setFrameAutosaveName("overlay")`: drag it to a corner, it stays there.
/// - `canBecomeKey` is true only while the question field is focused, then focus goes back to Balatro.
@MainActor
final class OverlayPanel: NSPanel {
    init(runtime: CoachRuntime) {
        // TODO: borderless, transparent background, NSHostingView(rootView: OverlayView(runtime: runtime)),
        //       320 x 420 default, resizable from the bottom edge.
        fatalError("not implemented")
    }

    override var canBecomeKey: Bool { fatalError("not implemented") }

    /// The global shortcut: show the panel, make it key, focus the question field.
    func focusQuestionField() { fatalError("not implemented") }
}
