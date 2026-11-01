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
                Text(view.title)
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
        Text(PilotView.clock(seconds))
            .font(Theme.pixelFont(2))
            .foregroundStyle(Theme.money)
            .monospacedDigit()
    }

    @ViewBuilder private var running: some View {
        if let run = view.run {
            ForEach(run.lines, id: \.self, content: line)
            ColouredText(run.doing, size: 13)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let starting = view.startingLine { line(starting) }
        if let choosing = view.choosingLine { line(choosing) }
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
        ForEach(result.lines, id: \.self, content: line)
        if case .failed(let reason) = result.ending {
            Text(reason)
                .font(Theme.body)
                .foregroundStyle(Theme.mult)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(view.bestTimes, id: \.title) { line($0.line) }
    }

    private func line(_ text: String) -> some View {
        ColouredText(text, size: 13)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
