import CryptoKit
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
    /// "Ante 3 · Big Blind · 3 hands, 2 discards". The overlay's headline and the transcript title.
    public let title: String
    /// The rendered prompt text. Its hash is the fingerprint, so "same decision" means exactly
    /// "the coach would be told the same thing". There's no second list of "decision-relevant fields" to keep in sync.
    public let prompt: String
    public let fingerprint: Fingerprint
    /// The answer when there's nothing to decide, so no turn is spent on it.
    public let instantAnswer: String?

    public var needsScreenshot: Bool {
        if case .openPack = kind { true } else { false }
    }

    /// Returns nil for writes that aren't decisions: round end, game over, new round, menu and unknown states.
    ///
    /// Rules, in order:
    /// 1. `openingBooster != nil` -> `.openPack(.shop)` (the `save_with_action` write, `button_callbacks.lua:2172`).
    /// 2. phase `.blindSelect` and the first held tag that fires on a blind choice opens a pack -> `.openPack(.skipTag)`.
    ///    Every blind-select save (`game.lua:3265`, the skip at `button_callbacks.lua:2771`, the boss reroll at `:2846`)
    ///    is followed at once by a loop over `G.GAME.tags`, oldest first, that fires the first `new_blind_choice` tag.
    ///    That includes `tag_boss`, which opens no pack, so a Boss Tag held ahead of a pack tag means no pack yet.
    /// 3. A pack phase -> `.openPack(.skipTag)`. When a pack closes, the next held pack tag fires, and the save
    ///    that follows (`button_callbacks.lua:2623`) is written in the new pack's state with that tag already gone.
    /// 4. `.selectingHand` -> `.playHand`; `.shop` -> `.shop`; `.blindSelect` -> `.blindSelect`.
    public static func detect(in snapshot: RunSnapshot, text: GameText) -> Decision? {
        guard let kind = kind(of: snapshot) else { return nil }
        let prompt = Prompt.decision(kind, snapshot, text)
        return Decision(
            kind: kind, snapshot: snapshot, title: Prompt.title(kind, snapshot, text),
            prompt: prompt, fingerprint: .of(prompt),
            instantAnswer: kind == .blindSelect ? Prompt.onlyBossLeft(snapshot, text) : nil)
    }

    private static func kind(of s: RunSnapshot) -> Kind? {
        if let pack = s.openingBooster { return .openPack(pack, from: .shop) }
        switch s.phase {
        case .blindSelect:
            let firing = s.tags.first { $0.opensPack != nil || $0.rawValue == "tag_boss" }
            if let tag = firing, let pack = tag.pack { return .openPack(pack, from: .skipTag(tag)) }
            return .blindSelect
        case .selectingHand: return .playHand
        case .shop: return .shop
        case .pack(let kind):
            let tag = TagKey.opening(kind)
            return tag.pack.map { .openPack($0, from: .skipTag(tag)) }
        case .roundEval, .gameOver, .other: return nil
        }
    }
}

extension TagKey {
    static func opening(_ kind: PackKind) -> TagKey {
        let rawValue = switch kind {
        case .standard: "tag_standard"
        case .arcana: "tag_charm"
        case .celestial: "tag_meteor"
        case .buffoon: "tag_buffoon"
        case .spectral: "tag_ethereal"
        }
        return TagKey(rawValue: rawValue)
    }

    /// The fixed pack each tag opens (`tag.lua:206-290`). The Charm and Meteor Tags pick `_mega_1` or `_mega_2`
    /// at random; both have the same size, so `_1` stands in.
    var pack: BoosterPack? {
        guard let kind = opensPack else { return nil }
        let (key, shown, picks) = switch kind {
        case .standard: ("p_standard_mega_1", 5, 2)
        case .arcana: ("p_arcana_mega_1", 5, 2)
        case .celestial: ("p_celestial_mega_1", 5, 2)
        case .buffoon: ("p_buffoon_mega_1", 4, 2)
        case .spectral: ("p_spectral_normal_1", 2, 1)
        }
        return BoosterPack(key: CenterKey(rawValue: key), kind: kind, cardsShown: shown, picks: picks)
    }
}

/// SHA-256 of a decision's prompt, hex. Persisted per run so a restart doesn't re-coach the same moment.
public struct Fingerprint: RawRepresentable, Sendable, Hashable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func of(_ prompt: String) -> Fingerprint {
        Fingerprint(rawValue: SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined())
    }
}
