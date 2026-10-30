import BalabroCore
import SwiftUI

/// Layout, top to bottom, sized so the "Do this now" block is readable at a glance from the game:
///
/// ```
/// ┌───────────────────────────────┐
/// │ ANTE 3 · BIG BLIND · HAND 2  ●│  headline in the pixel font, status dot
/// │ DO THIS NOW                   │  chip-blue label
/// │ 1 Discard J♦ 4♠ 3♥ 2♥         │  large, numbered, red/blue suit glyphs
/// │ 2 Play Q-Q-6-6                │
/// │ WHY  ▸                        │  collapsed by default, one tap to open
/// │ LESSON 12 · Straights in the… │  mult-red label, one line
/// │ [ Ask about this…        ] ⌃⌥␣│  the follow-up box
/// └───────────────────────────────┘
/// ```
struct OverlayView: View {
    let runtime: CoachRuntime
    var body: some View { fatalError("not implemented") }
}

struct AdviceView: View {
    let advice: Advice
    @State private var showWhy = false
    var body: some View { fatalError("not implemented") }
}

struct QuestionField: View {
    let onSubmit: (_ question: String, _ withScreenshot: Bool) -> Void
    var body: some View { fatalError("not implemented") }
}
