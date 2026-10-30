import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's `RegisterEventHotKey`. Chosen over an `NSEvent` global
/// monitor because it needs no Accessibility permission and it swallows the keystroke instead of
/// passing it on to Balatro.
@MainActor
final class HotKey {
    struct Combo: Sendable { var keyCode: UInt32; var modifiers: UInt32 }
    /// ⌃⌥Space. Balatro binds nothing with Control or Option.
    static let `default` = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

    init(_ combo: Combo, action: @escaping @MainActor () -> Void) { fatalError("not implemented") }
}
