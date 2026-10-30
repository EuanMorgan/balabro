import BalabroCore
import SwiftUI

/// Replaces the coach while the bot has a run. The bot plays in its own window, so this is the scoreboard.
struct PilotPanel: View {
    let view: PilotView
    let stop: () -> Void
    let close: () -> Void
    let again: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(Theme.pixelFont(2))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                clock
            }
            if let result = view.result {
                finished(result)
            } else {
                running
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if view.result == nil {
                    ChipButton("Stop", action: stop)
                } else {
                    ChipButton("Play again", action: again)
                    ChipButton("Close", action: close)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 280, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity, alignment: .topLeading)
        .background(Panel())
    }

    private var title: String {
        guard let result = view.result else { return view.goal == .naneinf ? "Chasing naneinf" : "Playing for you" }
        return switch result.ending {
        case .won: "Won"
        case .naneinf: "naneinf"
        case .lost: "Lost"
        case .stopped: "Stopped"
        case .failed: "Couldn't finish"
        }
    }

    @ViewBuilder private var clock: some View {
        if let result = view.result {
            time(result.seconds)
        } else if let startedAt = view.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                time(context.date.timeIntervalSince(startedAt))
            }
        }
    }

    private func time(_ seconds: Double) -> some View {
        Text(Self.clockText(seconds))
            .font(Theme.pixelFont(2))
            .foregroundStyle(Theme.money)
            .monospacedDigit()
    }

    private static func clockText(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    @ViewBuilder private var running: some View {
        if let run = view.run {
            line("Ante \(run.ante), round \(run.round), $\(run.dollars)")
            line("Best hand \(run.bestHandText)")
            ColouredText(run.doing, size: 13)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            line(view.status == .preparing ? "Opening the bot's own copy of the game" : "Starting the run")
        }
        if view.status == .askingClaude {
            line("Claude is choosing")
        }
        if let why = view.why, !why.isEmpty {
            ColouredText(why, size: 12)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let warning = view.warning {
            Text(warning)
                .font(Theme.body)
                .foregroundStyle(Theme.mult)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func finished(_ result: PilotResult) -> some View {
        line("Reached ante \(result.ante), round \(result.round)")
        line("Best hand \(result.bestHandText)")
        if case .failed(let reason) = result.ending {
            Text(reason)
                .font(Theme.body)
                .foregroundStyle(Theme.mult)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(view.bestTimes, id: \.title) { best in
            line("\(best.title): \(Self.clockText(best.seconds))")
        }
    }

    private func line(_ text: String) -> some View {
        ColouredText(text, size: 13)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
