import Foundation

/// The game's `get_blind_amount`. A save holds only the current blind's target, and the coach needs the coming ones.
public struct BlindScale: Sendable, Hashable, Codable {
    /// `GAME.modifiers.scaling`, which rises with the stake.
    var level: Int
    /// `GAME.starting_params.ante_scaling`, which Plasma Deck doubles.
    var deckMultiplier: Double

    private static let amounts: [[Double]] = [
        [300, 800, 2000, 5000, 11000, 20000, 35000, 50000],
        [300, 900, 2600, 8000, 20000, 36000, 60000, 100000],
        [300, 1000, 3200, 9000, 25000, 60000, 110000, 200000],
    ]
    private static let bossMultipliers: [CenterKey: Double] = [
        CenterKey(rawValue: "bl_wall"): 4, CenterKey(rawValue: "bl_needle"): 1, CenterKey(rawValue: "bl_final_vessel"): 6,
    ]

    func small(ante: Int) -> Double { deckMultiplier * base(ante: ante) }
    func big(ante: Int) -> Double { small(ante: ante) * 1.5 }
    func boss(_ key: CenterKey, ante: Int) -> Double { small(ante: ante) * (Self.bossMultipliers[key] ?? 2) }

    private func base(ante: Int) -> Double {
        guard ante >= 1 else { return 100 }
        let table = Self.amounts[min(max(level, 1), Self.amounts.count) - 1]
        guard ante > 8 else { return table[ante - 1] }
        let past = Double(ante - 8)
        let amount = (table[7] * pow(1.6 + pow(0.75 * past, 1 + 0.2 * past), past)).rounded(.down)
        guard amount.isFinite else { return amount }
        return amount - fmod(amount, pow(10, (log10(amount) - 1).rounded(.down)))
    }
}
