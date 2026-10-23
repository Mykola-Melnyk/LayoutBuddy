import XCTest
@testable import LayoutBuddy

final class LayoutDeciderTests: XCTestCase {
    private let decider = LayoutDecider()

    func testKnownWordTypedInWrongLayoutConverts() {
        XCTAssertEqual(decider.decide("ghbdsn", typedIn: .latin), .convert("привіт"))
        XCTAssertEqual(decider.decide("руддщ", typedIn: .cyrillic), .convert("hello"))
    }

    func testKnownWordInItsOwnLayoutIsKept() {
        XCTAssertEqual(decider.decide("hello", typedIn: .latin), .keep)
        XCTAssertEqual(decider.decide("привіт", typedIn: .cyrillic), .keep)
    }

    func testUserWordMakesBothReadingsPlausible() {
        var decider = LayoutDecider()
        decider.isUserWord = { word, script in word == "ghbdsn" && script == .latin }
        XCTAssertEqual(decider.decide("ghbdsn", typedIn: .latin), .ambiguous("привіт"))
    }

    func testLatinPunctuationKeysInsideAWordMeanUkrainianLetters() {
        XCTAssertEqual(decider.decide("j[jxt", typedIn: .latin), .convert("охоче"))
    }

    func testTrailingKeyIsALetterWhenThatMakesAKnownWord() {
        let result = decider.decide(token: "lzre.", typedIn: .latin)
        XCTAssertEqual(result.core, "lzre.")
        XCTAssertEqual(result.trailing, "")
        XCTAssertEqual(result.decision, .convert("дякую"))
    }

    func testTrailingKeyIsPunctuationOtherwise() {
        let result = decider.decide(token: "ghbdsn,", typedIn: .latin)
        XCTAssertEqual(result.core, "ghbdsn")
        XCTAssertEqual(result.trailing, ",")
        XCTAssertEqual(result.decision, .convert("привіт"))
    }

    func testUnknownWordsAreJudgedByLetterStatistics() {
        // Long, rare inflections that no lexicon lists.
        for (word, script) in [("перепрограмуванням", KeyboardLayoutConverter.Script.cyrillic),
                               ("misconfiguration", .latin)] {
            let other: KeyboardLayoutConverter.Script = script == .latin ? .cyrillic : .latin
            let typed = KeyboardLayoutConverter.convert(word, from: script, to: other)
            XCTAssertEqual(decider.decide(typed, typedIn: other), .convert(word))
        }
    }

    func testIdentifiersNamesAndAcronymsAreLeftAlone() {
        XCTAssertEqual(decider.decide("getValue", typedIn: .latin), .keep)
        XCTAssertEqual(decider.decide("Mykola", typedIn: .latin), .keep)
        XCTAssertEqual(decider.decide("kubectl", typedIn: .latin), .keep)
        XCTAssertEqual(decider.decide("PR", typedIn: .latin), .keep)
        XCTAssertEqual(decider.decide("don't", typedIn: .latin), .keep)
    }

    func testSingleLetters() {
        XCTAssertEqual(decider.decide("d", typedIn: .latin), .convert("в"))
        XCTAssertEqual(decider.decide("a", typedIn: .latin), .keep)
        // A capital letter on its own is too often a label ("Plan D").
        XCTAssertEqual(decider.decide("D", typedIn: .latin), .ambiguous("В"))
    }

    /// The decider runs inside the event tap: it must stay far below the
    /// time it takes to type a key.
    func testDecisionIsFastEnoughForTheEventTap() {
        let words = ["ghbdsn", "hello", "gthtghjuhfvedfyyzv", "kubectl", "руддщ", "привіт", "j[jxt"]
        _ = decider.decide("warm", typedIn: .latin)   // load the models outside the timing
        let rounds = 2_000
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<rounds {
            for word in words { _ = decider.decide(word, typedIn: word.first!.isASCII ? .latin : .cyrillic) }
        }
        let perWord = (CFAbsoluteTimeGetCurrent() - start) / Double(rounds * words.count)
        XCTAssertLessThan(perWord, 50e-6, "decide() took \(perWord * 1e6) µs per word")
    }
}
