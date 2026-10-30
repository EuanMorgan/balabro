import BalabroCore
import SwiftUI

/// What the panel shows while Claude works out a decision. Drawn from shapes because the public repo
/// can't ship the game's art. Every frame is a pure function of `time`, so nothing can get stuck mid-animation.
struct WaitingView: View {
    let kind: Decision.Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            WaitingFrame(kind: kind, time: context.date.timeIntervalSinceReferenceDate, moving: !reduceMotion)
        }
    }
}

struct WaitingFrame: View {
    let kind: Decision.Kind
    let time: Double
    var moving = true

    var body: some View {
        VStack(spacing: 14) {
            animation
                .frame(height: 76)
            Text(caption)
                .font(Theme.pixelFont(2))
                .foregroundStyle(Theme.chips)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    @ViewBuilder private var animation: some View {
        let t = moving ? time : 0
        switch kind {
        case .playHand: ScoreTally(time: t)
        case .shop: SpinningCoin(time: t)
        case .blindSelect: CardFan(time: t)
        case .openPack: WobblingPack(time: t)
        }
    }

    private var caption: String {
        let captions = switch kind {
        case .playHand: ["Counting the chips", "Checking the odds", "Reading your hand"]
        case .shop: ["Browsing the shelves", "Counting your money", "Weighing up the jokers"]
        case .blindSelect: ["Shuffling the deck", "Sizing up the blind", "Studying the Boss"]
        case .openPack: ["Peeking inside", "Reading the cards", "Picking a favourite"]
        }
        return captions[Int(time / 3.5) % captions.count]
    }
}

/// Blue chips times red mult, climbing like the game's score counter.
private struct ScoreTally: View {
    let time: Double

    var body: some View {
        let progress = (time / 6).truncatingRemainder(dividingBy: 1)
        let chips = 10 + Int(progress * 90)
        let mult = 1 + Int(progress * 8)
        let pulse = 1 + 0.06 * (1 - (progress * 8).truncatingRemainder(dividingBy: 1))
        HStack(spacing: 8) {
            tile("\(chips)", face: Theme.chips, lip: Theme.chipsDeep)
            Text("×").font(.system(size: 20, weight: .heavy)).foregroundStyle(Theme.mult)
            tile("\(mult)", face: Theme.mult, lip: Theme.multDeep)
                .scaleEffect(pulse)
        }
    }

    private func tile(_ number: String, face: Color, lip: Color) -> some View {
        Text(number)
            .font(Theme.pixelFont(3))
            .foregroundStyle(.white)
            .frame(width: 72, height: 44)
            .background(ChipTile(face: face, lip: lip))
    }
}

private struct SpinningCoin: View {
    let time: Double

    var body: some View {
        let hop = abs(sin(time * .pi / 1.6))
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Theme.moneyDeep)
                Circle().fill(Theme.money).padding(3)
                Circle().strokeBorder(Theme.moneyDeep, lineWidth: 2).padding(7)
                Text("$").font(Theme.pixelFont(3)).foregroundStyle(Theme.moneyDeep)
            }
            .frame(width: 50, height: 50)
            .scaleEffect(x: max(0.08, abs(cos(time * .pi / 1.6))))
            .offset(y: -8 * hop + 8)
            Ellipse()
                .fill(Theme.feltDeep)
                .frame(width: 40 - 12 * hop, height: 6)
        }
    }
}

/// A wave running through a fanned hand of cards.
private struct CardFan: View {
    let time: Double
    private static let suits: [(String, Color)] = [("♠", Theme.chips), ("♥", Theme.mult), ("♣", Theme.chips), ("♦", Theme.mult), ("♠", Theme.chips)]

    var body: some View {
        ZStack {
            ForEach(Self.suits.indices, id: \.self) { index in
                let position = Double(index) - 2
                card(Self.suits[index])
                    .rotationEffect(.degrees(position * 9))
                    .offset(x: position * 22, y: abs(position) * 3 - 10 * max(0, sin(time * 3 - Double(index) * 0.8)))
            }
        }
    }

    private func card(_ suit: (String, Color)) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.text)
            .overlay(Text(suit.0).font(.system(size: 18)).foregroundStyle(suit.1))
            .shadow(color: Theme.feltDeep, radius: 0, x: 0, y: 2)
            .frame(width: 34, height: 48)
    }
}

/// A booster pack wobbling on the spot, with a shine passing across the foil.
private struct WobblingPack: View {
    let time: Double

    var body: some View {
        let shine = (time / 2.4).truncatingRemainder(dividingBy: 1) * 2 - 0.5
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Theme.chips, Theme.mult], startPoint: .topLeading, endPoint: .bottomTrailing))
            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear],
                           startPoint: UnitPoint(x: shine - 0.3, y: 0), endPoint: UnitPoint(x: shine + 0.3, y: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(spacing: 0) {
                Rectangle().fill(Theme.muted).frame(height: 6)
                Spacer(minLength: 0)
                Rectangle().fill(Theme.muted).frame(height: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("?").font(Theme.pixelFont(3)).foregroundStyle(.white)
        }
        .frame(width: 50, height: 70)
        .rotationEffect(.degrees(sin(time * 2.5) * 5))
    }
}

/// Dots for a reply that's on its way. A fixed width stops the text beside them from shifting.
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            Text(String(repeating: ".", count: 1 + Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3))
                .font(Theme.pixelFont(2))
                .foregroundStyle(Theme.chips)
                .frame(width: 30, alignment: .leading)
        }
    }
}
