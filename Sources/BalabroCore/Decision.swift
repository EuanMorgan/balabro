import Foundation

/// A moment where the player has a choice to make and the coach should speak.
///
/// Derived from one snapshot alone, never from a diff against the previous one. A diff-based rule
/// breaks when the game coalesces writes (it writes at most every 5 s on macOS, `globals.lua:52`,
/// keeping only the newest `save_run`), or when the app starts mid-run.
public struct Decision: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case playHand
        case shop
        case blindSelect
        /// The save can't show the cards, so this decision needs a screenshot before it can be coached.
        case openPack(BoosterPack, from: PackSource)
    }
    public enum PackSource: Sendable, Hashable { case shop, skipTag(TagKey) }

    public let kind: Kind
    public let snapshot: RunSnapshot
    /// The rendered prompt text. Its hash is the fingerprint, so "same decision" means exactly
    /// "the coach would be told the same thing". There's no second list of "decision-relevant fields" to keep in sync.
    public let prompt: String
    public let fingerprint: Fingerprint

    public var needsScreenshot: Bool {
        if case .openPack = kind { true } else { false }
    }

    /// Returns nil for writes that aren't decisions: round end, game over, new round, menu, unknown states.
    ///
    /// Rules, in order:
    /// 1. `openingBooster != nil` -> `.openPack(.shop)` (the `save_with_action` write, `button_callbacks.lua:2172`).
    /// 2. phase `.blindSelect` and the newest tag `opensPack` -> `.openPack(.skipTag)`
    ///    (the `skip_blind` write at `button_callbacks.lua:2771` lands before the tag fires).
    /// 3. phase `.pack(kind)` -> `.openPack` (unlikely, the game doesn't save mid-pack, but harmless).
    /// 4. `.selectingHand` with a non-empty hand -> `.playHand`; `.shop` -> `.shop`; `.blindSelect` -> `.blindSelect`.
    public static func detect(in snapshot: RunSnapshot, text: GameText) -> Decision? {
        // TODO: rules above, then prompt = Prompt.decision(kind, snapshot, text), fingerprint = .of(prompt).
        // TODO: rule 2 can misfire if a pack tag was held from an earlier skip and is still unapplied.
        //       Check `tag.lua:206`: does a held pack tag always fire on the very next new_blind_choice?
        fatalError("not implemented")
    }
}

/// SHA-256 of a decision's prompt, hex. Persisted per run so a restart doesn't re-coach the same moment.
public struct Fingerprint: RawRepresentable, Sendable, Hashable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func of(_ prompt: String) -> Fingerprint { fatalError("not implemented") }
}
