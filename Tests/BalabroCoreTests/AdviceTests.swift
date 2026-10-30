import BalabroCore
import Testing

@Suite
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

    @Test func halfStreamedHeadingIsNotShownAsText() {
        let a = Advice(markdown: "**Do this now:**\n1. Discard 7♣.\n**Wh")
        #expect(a.doNow == ["Discard 7♣."])
        #expect(a.rest == "")
    }

    @Test func halfStreamedStepNumberIsNotAppendedToTheStepAbove() {
        #expect(Advice(markdown: "**Do this now:**\n1. Discard 7♣.\n2").doNow == ["Discard 7♣."])
    }

    @Test func wrappedStepContinuesTheStepAbove() {
        let a = Advice(markdown: "**Do this now:**\n1. Play Q-Q-6-6,\n   or a Full House if you draw one.\n2. Sell nothing.")
        #expect(a.doNow == ["Play Q-Q-6-6, or a Full House if you draw one.", "Sell nothing."])
    }

    @Test func answerThatIgnoresTheFormatLandsInRest() {
        let a = Advice(markdown: "Keep the 6 because it pairs with the 6 in your hand.\n\nThe 5 doesn't.")
        #expect(a.doNow.isEmpty && a.why.isEmpty && a.lesson == nil)
        #expect(a.rest == "Keep the 6 because it pairs with the 6 in your hand.\n\nThe 5 doesn't.")
    }

    @Test func plainHeadingsAndTextOnTheHeadingLine() {
        let a = Advice(markdown: "## Do this now\n- Skip the Small Blind.\n**Why:** The Handy Tag pays more than the blind.\nLesson 3: skip early when the tag is good\nSkipping costs nothing at ante 1.")
        #expect(a.doNow == ["Skip the Small Blind."])
        #expect(a.why == ["The Handy Tag pays more than the blind."])
        #expect(a.lesson == .init(number: 3, title: "skip early when the tag is good", body: "Skipping costs nothing at ante 1."))
    }

    @Test func lineThatStartsWithLessonsIsNotAHeading() {
        let a = Advice(markdown: "**Why:**\nLessons from the last ante: keep Clubs.")
        #expect(a.why == ["Lessons from the last ante: keep Clubs."])
        #expect(a.lesson == nil)
    }
}
