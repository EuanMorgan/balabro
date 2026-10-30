import AppKit
import SwiftUI

/// The always-on-top coaching panel.
///
/// - `.nonactivatingPanel`: clicking it doesn't activate Balabro, so Balatro keeps focus and stays fullscreen.
/// - `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` plus the app's
///   `.accessory` policy let it show on Balatro's fullscreen Space.
/// - `level = .screenSaver`: LÖVE's SDL backend can raise a fullscreen window above `.floating`;
///   `.screenSaver` sits above it without covering system alerts.
/// - `becomesKeyOnlyIfNeeded`: the panel takes key only for a click in the question field, so typing
///   goes to the field and every other click leaves the game's keyboard alone.
@MainActor
final class OverlayPanel: NSPanel {
    init(runtime: CoachRuntime, pilot: PilotRuntime, updater: Updater?) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 280, height: 240)
        contentView = NSHostingView(rootView: OverlayView(runtime: runtime, pilot: pilot, updater: updater))
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 24, y: screen.maxY - frame.height - 24))
        }
        setFrameAutosaveName("overlay")
    }

    override var canBecomeKey: Bool { true }

    /// The global shortcut: show the panel, make it key, focus the question field.
    func focusQuestionField() {
        orderFrontRegardless()
        makeKey()
        if let field = contentView.flatMap(Self.textField) { makeFirstResponder(field) }
    }

    /// Escape in the question field hands the keyboard back to the game.
    override func cancelOperation(_ sender: Any?) {
        makeFirstResponder(nil)
        resignKey()
    }

    private static func textField(in view: NSView) -> NSTextField? {
        (view as? NSTextField).flatMap { $0.isEditable ? $0 : nil } ?? view.subviews.lazy.compactMap(textField).first
    }
}
