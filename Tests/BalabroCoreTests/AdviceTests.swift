import BalabroCore
import Testing

@Suite(.disabled("sketch: bodies not implemented"))
struct AdviceTests {
    /// The format from the user's old chat, verbatim.
    @Test func oldChatFormat() {
        let a = Advice(markdown: """
            **Do this now:**
            1. Discard J♦ 4♠ 3♥ 2♥.
            2. Play Q-Q-6-6.

            **Why:**
            - With Mystic Summit on, Two Pair scores about 2,500 against the 800 target.

            **Lesson 12: look for Straights in the middle cards**
            One sentence.
            """)
        #expect(a.doNow == ["Discard J♦ 4♠ 3♥ 2♥.", "Play Q-Q-6-6."])
        #expect(a.why == ["With Mystic Summit on, Two Pair scores about 2,500 against the 800 target."])
        #expect(a.lesson == .init(number: 12, title: "look for Straights in the middle cards", body: "One sentence."))
    }

    @Test func halfStreamedFirstStep() {
        #expect(Advice(markdown: "**Do this now:**\n1. Disc").doNow == ["Disc"])
    }
}
