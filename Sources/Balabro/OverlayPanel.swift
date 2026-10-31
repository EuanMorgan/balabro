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
        moveToCorner()
        setFrameAutosaveName("overlay")
    }

    override var canBecomeKey: Bool { true }

    func moveToCorner() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 24, y: screen.maxY - frame.height - 24))
    }

    private var drag: (mouse: NSPoint, origin: NSPoint)?

    /// The title moves the panel even if `isMovableByWindowBackground` doesn't start a drag, which was reported on macOS 27.
    /// The header's buttons are left out, because a button still fires when the mouse comes up on it.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let point = event.locationInWindow
            let onTitle = point.y > frame.height - Self.titleHeight && point.x < frame.width - Self.headerButtonsWidth
            drag = onTitle ? (convertPoint(toScreen: point), frame.origin) : nil
        case .leftMouseDragged:
            if let drag {
                let mouse = convertPoint(toScreen: event.locationInWindow)
                setFrameOrigin(NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y))
                return
            }
        case .leftMouseUp:
            drag = nil
        default:
            break
        }
        super.sendEvent(event)
    }

    private static let titleHeight: CGFloat = 44
    private static let headerButtonsWidth: CGFloat = 100

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
