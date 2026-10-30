import BalabroCore
import SwiftUI

/// Layout, top to bottom, sized so the "Do this now" block is readable at a glance from the game:
///
/// ```
/// ┌───────────────────────────────┐
/// │ Ante 3 · Big Blind · hand 2  ●│  headline in the pixel font, status dot
/// │ Do this now                   │  chip-blue label
/// │ 1 Discard J♦ 4♠ 3♥ 2♥         │  large, numbered, red/blue suit glyphs
/// │ 2 Play Q-Q-6-6                │
/// │ Why  ▸                        │  collapsed by default, one tap to open
/// │ Lesson 12  Straights in the…  │  mult-red label, one line
/// │ [ Ask about this…        ] ⌃⌥␣│  the follow-up box
/// └───────────────────────────────┘
/// ```
struct OverlayView: View {
    let runtime: CoachRuntime
    var body: some View {
        OverlayContent(view: runtime.view, ask: runtime.ask, retry: runtime.retry)
    }
}

struct OverlayContent: View {
    let view: CoachView
    let ask: (_ question: String, _ withScreenshot: Bool) -> Void
    let retry: () -> Void
    var showWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            if let problem = view.problem {
                ProblemBanner(problem: problem, canRetry: view.canRetry, retry: retry)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            if let queued = view.queuedQuestion {
                Text("Next: \(queued)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            QuestionField(onSubmit: ask)
                .padding(10)
        }
        .frame(minWidth: 280, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity, alignment: .top)
        .background(Panel())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(view.headline.isEmpty ? "Balabro" : view.headline)
                .font(Theme.pixelFont(2))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            StatusLight(status: view.status)
        }
    }

    @ViewBuilder private var content: some View {
        if let advice = view.advice ?? (view.status == .ready ? view.history.last.map { Advice(markdown: $0.advice) } : nil) {
            AdviceView(advice: advice, streaming: view.status == .answering, showWhy: showWhy)
        } else {
            switch view.status {
            case .waitingForRun:
                Placeholder(title: "Waiting for a run",
                            detail: "Start or continue a run in Balatro. Advice appears here each time you draw a hand, visit the shop, open a pack or pick a blind.")
            case .lookingAtPack:
                Placeholder(title: "Looking at the pack", detail: "Taking a screenshot once the cards land.")
            case .thinking, .answering:
                Placeholder(title: "Reading the board", detail: "Advice streams in here as Opus writes it.")
            case .ready:
                Placeholder(title: "Ready", detail: "Ask anything about this run below.")
            }
        }
    }
}

struct AdviceView: View {
    let advice: Advice
    var streaming = false
    @State private var showWhy = false

    init(advice: Advice, streaming: Bool = false, showWhy: Bool = false) {
        (self.advice, self.streaming, self._showWhy) = (advice, streaming, State(initialValue: showWhy))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !advice.doNow.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Do this now")
                        .font(Theme.pixelFont(2))
                        .foregroundStyle(Theme.chips)
                    ForEach(Array(advice.doNow.enumerated()), id: \.offset) { index, step in
                        StepRow(number: index + 1, text: step)
                    }
                }
            }
            if !advice.why.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        showWhy.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Why")
                                .font(Theme.pixelFont(2))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .heavy))
                                .rotationEffect(.degrees(showWhy ? 90 : 0))
                        }
                        .foregroundStyle(Theme.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showWhy {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(advice.why.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(Theme.muted.opacity(0.6)).frame(width: 4, height: 4)
                                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                                    SuitText(line, size: 13).foregroundStyle(Theme.text.opacity(0.88))
                                }
                            }
                        }
                    }
                }
            }
            if let lesson = advice.lesson {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(lesson.number.map { "Lesson \($0)" } ?? "Lesson")
                            .font(Theme.pixelFont(2))
                            .foregroundStyle(Theme.mult)
                        Text(lesson.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(showWhy ? nil : 1)
                    }
                    if showWhy, !lesson.body.isEmpty {
                        SuitText(lesson.body, size: 13).foregroundStyle(Theme.muted)
                    }
                }
            }
            if !advice.rest.isEmpty {
                SuitText(advice.rest, size: 13).foregroundStyle(Theme.text.opacity(0.88))
            }
            if streaming {
                Text("…").font(Theme.pixelFont(2)).foregroundStyle(Theme.chips)
            }
        }
        .textSelection(.enabled)
    }
}

struct QuestionField: View {
    let onSubmit: (_ question: String, _ withScreenshot: Bool) -> Void
    @State private var question = ""
    @State private var withScreenshot = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("Ask about this…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .onSubmit {
                    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSubmit(trimmed, withScreenshot)
                    question = ""
                    withScreenshot = false
                }
            Button {
                withScreenshot.toggle()
            } label: {
                Image(systemName: withScreenshot ? "camera.fill" : "camera")
                    .font(.system(size: 12))
                    .foregroundStyle(withScreenshot ? Theme.chips : Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Attach a screenshot of the game")
            Text("⌃⌥Space")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.feltDeep))
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(Theme.pixelFont(2))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(ChipTile())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            SuitText(text, size: 15, weight: .semibold)
                .foregroundStyle(Theme.text)
        }
    }
}

private struct SuitText: View {
    let attributed: AttributedString
    let size: CGFloat
    let weight: Font.Weight

    init(_ markdown: String, size: CGFloat, weight: Font.Weight = .regular) {
        var text = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for (glyphs, color) in [("♥♦♡♢", Theme.mult), ("♠♣♤♧", Theme.chips)] {
            for run in text.characters.indices where glyphs.contains(text.characters[run]) {
                text[run..<text.characters.index(after: run)].foregroundColor = color
            }
        }
        (attributed, self.size, self.weight) = (text, size, weight)
    }

    var body: some View {
        Text(attributed)
            .font(.system(size: size, weight: weight))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatusLight: View {
    let status: CoachView.Status

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .waitingForRun: Theme.muted.opacity(0.5)
        case .lookingAtPack, .thinking, .answering: Theme.chips
        case .ready: Theme.money
        }
    }
}

private struct Placeholder: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.pixelFont(2)).foregroundStyle(Theme.chips)
            Text(detail).font(Theme.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProblemBanner: View {
    let problem: Problem
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if canRetry {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .font(Theme.pixelFont(1))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ChipTile())
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mult.opacity(0.85)))
    }

    private var message: String {
        switch problem {
        case .noRun: "Start a run in Balatro first, then ask again."
        case .screenRecordingDenied:
            "Allow Balabro in System Settings › Privacy & Security › Screen Recording so the coach can see pack cards."
        case .saveUnreadable: "Couldn't read Balatro's save file. Advice resumes at the next save."
        case .turnFailed(.notLoggedIn): "Claude isn't logged in. Run `claude` in Terminal and log in, then retry."
        case .turnFailed(.cliNotFound): "Couldn't find the claude command. Install Claude Code, then restart Balabro."
        case .turnFailed(.rateLimited(let resetsAt)):
            resetsAt.map { "Claude usage limit reached. Resets \($0.formatted(date: .omitted, time: .shortened))." }
                ?? "Claude usage limit reached."
        case .turnFailed(.exited(let status, let tail)): "Claude stopped with status \(status). \(tail.suffix(160))"
        case .turnFailed(.malformedOutput): "Claude's reply couldn't be read."
        }
    }
}

private struct ChipTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Theme.chipsDeep)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 5).fill(Theme.chips).padding(.bottom, 2)
            }
    }
}

private struct Panel: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Theme.feltDeep)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.felt)
                    .padding(.bottom, 4)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.feltRaised, lineWidth: 1.5).padding(.bottom, 4))
            }
    }
}
