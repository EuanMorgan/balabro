import BalabroCore
import SwiftUI

/// Layout, top to bottom, sized so the "Do this now" block is readable at a glance from the game:
///
/// ```
/// ┌───────────────────────────────┐
/// │ Ante 3 · Big Blind · hand 2  ●│  headline in the pixel font, status dot
/// │ Score 92 / 300            $14 │  from the save
/// │ Do this now    From your save │  chip-blue label, and what the coach could see
/// │ 1 Discard J♦ 4♠ 3♥ 2♥         │  large, numbered, red/blue suit glyphs
/// │ 2 Play Q-Q-6-6                │
/// │ Two Pair        [46] × [2] = 92 │  chip blue and mult red, as in the game
/// │                               │  everything above stays put; everything below scrolls
/// │ Why ▸ Going for a Straight    │  the goal stays visible, the reasons open with one tap
/// │ Lesson 12                     │  mult-red label
/// │ Straights in the middle cards │  title, then the lesson in full
/// │ ───────────────────────────── │
/// │ [why keep the 6?]             │  the player's questions about this decision
/// │ It pairs with the 6 in…       │  and the replies, until the next decision clears them
/// │ [ Ask about this…        ] ⌃⌥␣│  the follow-up box
/// └───────────────────────────────┘
/// ```
struct OverlayView: View {
    let runtime: CoachRuntime
    let updater: Updater?

    var body: some View {
        OverlayContent(view: runtime.view, ask: runtime.ask, retry: runtime.retry, update: updater?.status ?? .none, install: {
            Task { if await updater?.install() == true { NSApp.terminate(nil) } }
        }, screenAccess: ScreenAccess.isGranted)
    }
}

struct OverlayContent: View {
    let view: CoachView
    let ask: (_ question: String, _ withScreenshot: Bool) -> Void
    let retry: () -> Void
    var update = Updater.Status.none
    var install: () -> Void = {}
    var screenAccess = true
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
            // The steps stay pinned while there's room for the rest under them. Otherwise everything scrolls
            // together, so nothing is out of reach. The ideal height is what makes the first layout count as fitting.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    pinnedSteps
                    scrolling(content)
                        .frame(idealHeight: 80, maxHeight: .infinity)
                }
                scrolling(VStack(spacing: 0) {
                    pinnedSteps
                    content
                })
            }
            if let queued = view.queuedQuestion {
                Text("Next: \(queued)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            if !screenAccess {
                NoticeRow(message: "Screen Recording is off, so the coach can't see packs") { ChipButton("Allow", action: ScreenAccess.ask) }
                    .padding(.horizontal, 16)
            }
            UpdateRow(status: update, install: install)
                .padding(.horizontal, 16)
            QuestionField(onSubmit: ask)
                .padding(10)
        }
        .frame(minWidth: 280, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity, alignment: .top)
        .background(Panel())
    }

    private static let contentID = "content"

    @ViewBuilder private var pinnedSteps: some View {
        if let advice = view.advice, !advice.doNow.isEmpty {
            DoThisNow(steps: advice.doNow, score: advice.score, sawScreen: view.sawScreen)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
    }

    private func scrolling(_ inner: some View) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                inner
                    .id(Self.contentID)
            }
            .scrollIndicators(.never)
            .onChange(of: view.thread) {
                if !view.thread.isEmpty { scroll.scrollTo(Self.contentID, anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(view.headline.isEmpty ? "Balabro" : view.headline)
                    .font(Theme.pixelFont(2))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                StatusLight(status: view.status)
            }
            if let standing = view.standing {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let score = standing.score {
                        Text("Score")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        Text(score)
                            .font(Theme.pixelFont(2))
                            .foregroundStyle(Theme.text)
                    }
                    Spacer(minLength: 0)
                    Text("$\(standing.dollars)")
                        .font(Theme.pixelFont(2))
                        .foregroundStyle(Theme.money)
                }
            }
        }
    }

    private var content: some View {
        scrolledContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
    }

    @ViewBuilder private var scrolledContent: some View {
        if view.advice != nil || !view.thread.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if let advice = view.advice {
                    AdviceView(advice: advice, streaming: view.status == .answering && view.thread.isEmpty, showWhy: showWhy)
                }
                if !view.thread.isEmpty {
                    FollowUpThread(thread: view.thread, waiting: view.status != .ready)
                }
            }
        } else {
            if let kind = view.waitingOn {
                WaitingView(kind: kind, capturing: view.status == .lookingAtPack)
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch view.status {
        case .waitingForRun:
            Placeholder(title: "Waiting for a run",
                        detail: "Start or continue a run in Balatro. Advice appears here each time you draw a hand, visit the shop, open a pack or pick a blind.")
        case .lookingAtPack, .thinking, .answering:
            Placeholder(title: "Reading the board")
        case .ready:
            Placeholder(title: "Ready", detail: "Ask anything about this run below.")
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
            if !advice.why.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        showWhy.toggle()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Why")
                                .font(Theme.pixelFont(2))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .heavy))
                                .rotationEffect(.degrees(showWhy ? 90 : 0))
                            if let goal = advice.goal { Goal(text: goal).padding(.leading, 2) }
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
            if advice.why.isEmpty, let goal = advice.goal { Goal(text: goal) }
            if let lesson = advice.lesson {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lesson.number.map { "Lesson \($0)" } ?? "Lesson")
                        .font(Theme.pixelFont(2))
                        .foregroundStyle(Theme.mult)
                    Text(lesson.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !lesson.body.isEmpty {
                        SuitText(lesson.body, size: 13).foregroundStyle(Theme.muted)
                    }
                }
            }
            if !advice.rest.isEmpty {
                SuitText(advice.rest, size: 13).foregroundStyle(Theme.text.opacity(0.88))
            }
            if streaming { ThinkingDots() }
        }
        .textSelection(.enabled)
    }
}

private struct UpdateRow: View {
    let status: Updater.Status
    let install: () -> Void

    var body: some View {
        switch status {
        case .none:
            EmptyView()
        case .available(let release):
            NoticeRow(message: "Version \(release.version) is available") { ChipButton("Update", action: install) }
        case .installing(let release):
            NoticeRow(message: "Updating to \(release.version)…") { EmptyView() }
        case .failed(let release):
            NoticeRow(message: "Couldn't update") { ChipButton("Download") { NSWorkspace.shared.open(release.page) } }
        }
    }
}

private struct NoticeRow<Action: View>: View {
    let message: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action
        }
    }
}

private struct DoThisNow: View {
    let steps: [String]
    let score: [Advice.ScoreLine]
    let sawScreen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Do this now")
                    .font(Theme.pixelFont(2))
                    .foregroundStyle(Theme.chips)
                Spacer(minLength: 0)
                Label(sawScreen ? "Saw your screen" : "From your save", systemImage: sawScreen ? "camera.fill" : "doc.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                StepRow(number: index + 1, text: step)
            }
            ForEach(Array(score.enumerated()), id: \.offset) { _, line in
                ScoreRow(line: line)
            }
        }
        .textSelection(.enabled)
    }
}

private struct FollowUpThread: View {
    let thread: [CoachView.FollowUp]
    let waiting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Theme.feltRaised).frame(height: 1)
            ForEach(Array(thread.enumerated()), id: \.offset) { index, followUp in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if followUp.sawScreen { Image(systemName: "camera.fill").font(.system(size: 10)) }
                        SuitText(followUp.question, size: 13, weight: .medium)
                    }
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.feltDeep))
                    if !followUp.reply.isEmpty {
                        SuitText(followUp.reply, size: 13).foregroundStyle(Theme.text.opacity(0.88))
                    }
                    if followUp.changedSteps {
                        Text("Steps updated above")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.chips)
                    }
                    if waiting, index == thread.count - 1 { ThinkingDots() }
                }
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

private struct ScoreRow: View {
    let line: Advice.ScoreLine

    var body: some View {
        HStack(spacing: 6) {
            SuitText(line.label, size: 13, weight: .medium)
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            if let sum = line.sum {
                HStack(spacing: 4) {
                    tile(sum.chips, ChipTile())
                    symbol("×")
                    tile(sum.mult, ChipTile(face: Theme.mult, lip: Theme.multDeep))
                    symbol("=")
                    Text(sum.total).font(Theme.pixelFont(2)).foregroundStyle(Theme.text)
                }
                .fixedSize()
            }
        }
    }

    private func tile(_ number: String, _ background: ChipTile) -> some View {
        Text(number)
            .font(Theme.pixelFont(2))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .background(background)
    }

    private func symbol(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
    }
}

private struct Goal: View {
    let text: String

    var body: some View {
        SuitText(text, size: 13, weight: .semibold).foregroundStyle(Theme.text)
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
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.pixelFont(2)).foregroundStyle(Theme.chips)
            if let detail {
                Text(detail).font(Theme.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
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
            if canRetry { ChipButton("Retry", action: retry) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mult.opacity(0.85)))
    }

    private var message: String {
        switch problem {
        case .noRun: "Start a run in Balatro first, then ask again."
        case .screenRecordingDenied:
            "Couldn't take a screenshot of Balatro. Check Balabro is allowed in System Settings › Privacy & Security › Screen Recording, then quit and reopen it."
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

private struct ChipButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) { (self.title, self.action) = (title, action) }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Theme.pixelFont(1))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ChipTile())
    }
}

struct ChipTile: View {
    var face = Theme.chips
    var lip = Theme.chipsDeep

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(lip)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 5).fill(face).padding(.bottom, 2)
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
