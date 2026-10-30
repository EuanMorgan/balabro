import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's `RegisterEventHotKey`. Chosen over an `NSEvent` global
/// monitor because it needs no Accessibility permission and it swallows the keystroke instead of
/// passing it on to Balatro.
@MainActor
final class HotKey {
    struct Combo: Sendable { var keyCode: UInt32; var modifiers: UInt32 }
    /// ⌃⌥Space. Balatro binds nothing with Control or Option.
    static let `default` = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(_ combo: Combo, action: @escaping @MainActor () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { Unmanaged<HotKey>.fromOpaque(context!).takeUnretainedValue().action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: OSType(0x426C_6272), id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}
