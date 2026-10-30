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

    @Test func scoreBlockSplitsIntoChipsMultAndTotal() {
        let a = Advice(markdown: """
            **Do this now:**
            1. Play K♥ K♣ 3♠ 3♦.

            **Score:**
            - Two Pair: 46 x 2 = 92
            - Full House, if you draw it: 1,076 × 4.5 = 4,842.

            **Why:**
            - It beats the blind.
            """)
        #expect(a.doNow == ["Play K♥ K♣ 3♠ 3♦."])
        #expect(a.score == [
            .init(label: "Two Pair", sum: .init(chips: "46", mult: "2", total: "92")),
            .init(label: "Full House, if you draw it", sum: .init(chips: "1,076", mult: "4.5", total: "4,842")),
        ])
        #expect(a.why == ["It beats the blind."])
    }

    @Test func scoreLineWhoseHandNameStartsWithANumberKeepsIt() {
        let a = Advice(markdown: "**Score:**\n- 3 of a Kind: 30 x 3 = 90")
        #expect(a.score == [.init(label: "3 of a Kind", sum: .init(chips: "30", mult: "3", total: "90"))])
    }

    @Test func scoreLineInAnotherFormStaysReadable() {
        let a = Advice(markdown: "**Score:**\n- Pair: **about 60**")
        #expect(a.score == [.init(label: "Pair: about 60")])
    }

    @Test func goalIsOneLineApartFromTheReasons() {
        let a = Advice(markdown: """
            **Do this now:**
            1. Discard 7♠.

            **Goal:** Going for a Straight

            **Why:**
            - 4 outs.
            """)
        #expect(a.goal == "Going for a Straight")
        #expect(a.why == ["4 outs."])
        #expect(a.doNow == ["Discard 7♠."])
    }

    @Test func goalOnItsOwnLineUnderTheHeadingStillParses() {
        #expect(Advice(markdown: "**Goal:**\nSaving up for a joker").goal == "Saving up for a joker")
    }

    @Test func answerWithoutAGoalHasNone() {
        #expect(Advice(markdown: "**Do this now:**\n1. Discard 7♠.").goal == nil)
    }
}
