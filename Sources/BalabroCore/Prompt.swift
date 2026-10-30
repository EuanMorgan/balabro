import Foundation

/// Everything Claude is told. Plain text, deterministic for a given snapshot (sorted keys, fixed order),
/// because `Decision.fingerprint` hashes it.
enum Prompt {
    /// Passed with `--system-prompt` on every turn. Replaces Claude Code's coding prompt entirely.
    static let system = """
        You are a Balatro coach watching the player's run through their save file. Each message is the
        current game state at one decision, or a question from the player.

        Always answer in this exact shape:

        **Do this now:**
        1. One concrete action per step. Name cards exactly as given, e.g. "Discard 7♣ 4♣ 2♠".

        **Why:**
        - Short bullets. Show score maths against the blind target. Count outs when drawing matters.
        - Mention joker order or card order when it changes the score.

        **Lesson N: title** (optional; only when there's a real lesson; number lessons across the whole run)
        One or two sentences.

        Keep a running plan for the run and refer back to it. At a blind select, answer in one line
        unless the Boss Blind's rule or a skip tag matters. Joker text has #1#-style placeholders:
        fill them from the joker's live values. Face-down cards are unknown to the player and to you.
        The deck is listed as counts because the draw order is unknown. Never guess at it.
        If a booster pack's cards are not shown or the screenshot is missing, ask the player to list them.
        """

    /// Example (`.playHand`), the shape every decision prompt follows:
    /// ```
    /// DECISION: play or discard
    /// Ante 3, Big Blind (target 2,400). Scored 830. Hands 3, discards 2. $14.
    /// Hand (left to right): K♠ Q♥ Q♦ 9♣ 6♥ 6♠ 4♦ 2♣
    /// Jokers (left to right, 4/5):
    /// - Flower Pot: X#1# Mult if poker hand contains a Diamond card, Club card, Heart card, and Spade card. [extra=3]
    /// Consumables (1/2): The Hermit
    /// Poker hands: Pair L2 (15 x 3), Two Pair L3 (40 x 4), ...
    /// Deck (34 left): A♠ x2, K♠, ...
    /// ```
    static func decision(_ kind: Decision.Kind, _ s: RunSnapshot, _ text: GameText) -> String {
        // TODO: one section per field, each sorted or in on-screen order. No timestamps, no counters
        //       that change without the decision changing, or the fingerprint stops dropping duplicates.
        fatalError("not implemented")
    }

    static func question(_ q: String, packContentsUnknown: Bool) -> String { fatalError("not implemented") }

    /// "Ante 3 · Big Blind · hand 2". The overlay's headline and the transcript title.
    static func title(_ kind: Decision.Kind, _ s: RunSnapshot, _ text: GameText) -> String { fatalError("not implemented") }

    static func card(_ c: HandCard) -> String {
        // TODO: "Q♥", "10♠ (Glass, Red seal)", "face-down".
        fatalError("not implemented")
    }
}
