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

    @Test func roundedScoreLineStillGetsItsNumbers() {
        let a = Advice(markdown: "**Score:**\n- Pair of 6s: 230 x 1,291 ≈ 296,900\n- Instead, Pair of 4s: 226 x 1,291 ~ 291,800")
        #expect(a.score == [
            .init(label: "Pair of 6s", sum: .init(chips: "230", mult: "1,291", total: "296,900")),
            .init(label: "Instead: Pair of 4s", sum: .init(chips: "226", mult: "1,291", total: "291,800"), isAlternative: true),
        ])
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

    @Test func insteadLineIsMarkedAsTheAlternative() {
        let a = Advice(markdown: "**Score:**\n- Pair of 9s: 58 x 33 = 1,914\n- Instead, Full House: 78 x 4 = 312")
        #expect(a.score == [
            .init(label: "Pair of 9s", sum: .init(chips: "58", mult: "33", total: "1,914")),
            .init(label: "Instead: Full House", sum: .init(chips: "78", mult: "4", total: "312"), isAlternative: true),
        ])
    }

    @Test func scoreLineSaysWhatTheHandDoesToTheBlind() {
        func line(_ total: String) -> Advice.ScoreLine { .init(label: "Flush", sum: .init(chips: "1", mult: "1", total: total)) }
        #expect(line("2,412").outcome(chipsNeeded: 2000) == .clears)
        #expect(line("2,000").outcome(chipsNeeded: 2000) == .clears)
        #expect(line("1,914").outcome(chipsNeeded: 2000) == .leaves("86"))
        #expect(line("1,000").outcome(chipsNeeded: 3500) == .leaves("2,500"))
        #expect(line("lots").outcome(chipsNeeded: 2000) == nil)
        #expect(Advice.ScoreLine(label: "Pair: about 60").outcome(chipsNeeded: 2000) == nil)
    }

    @Test func scoreLinesHandleNumbersUpToNaneinf() {
        let a = Advice(markdown: """
            **Score:**
            - High Card: 1.2e150 x 3.5e157 = naneinf
            - Instead, Pair of Kings: 2.5e+40 x 4e12 = 1e53
            """)
        #expect(a.score == [
            .init(label: "High Card", sum: .init(chips: "1.2e150", mult: "3.5e157", total: "naneinf")),
            .init(label: "Instead: Pair of Kings", sum: .init(chips: "2.5e+40", mult: "4e12", total: "1e53"), isAlternative: true),
        ])
        #expect(a.score[0].outcome(chipsNeeded: 1e288) == .clears)
        #expect(a.score[1].outcome(chipsNeeded: 3e53) == .leaves("2.000e53"))
        // Ante 39's target overflows to nan, and the game can't beat it with any score.
        #expect(a.score[0].outcome(chipsNeeded: .nan) == .leaves("naneinf"))
    }
}
