import XCTest
@testable import LayoutBuddy

/// Replays labelled typing samples through the wrong-layout decider and
/// reports accuracy, so "it feels buggy" becomes numbers you can move.
///
/// Corpus files live in `Corpus/*.tsv`, one sample per line:
///
///     <text as the keys produced it><TAB><text the user meant>
///
/// Both columns have the same length (layout conversion is one key → one
/// character). Lines starting with `#` are comments. Add real-life misses here
/// as you hit them; run `swift test --filter ReplayCorpusTests` for the report.
final class ReplayCorpusTests: XCTestCase {

    private typealias Script = KeyboardLayoutConverter.Script

    private struct Outcome {
        var converted = 0          // wrong layout, fixed correctly
        var kept = 0               // right layout, left alone
        var ambiguousFixable = 0   // wrong layout, offered to the hotkey
        var ambiguousKept = 0      // right layout, offered to the hotkey
        var missed: [String] = []  // wrong layout, left alone
        var wrong: [String] = []   // right layout but changed, or changed into the wrong text
        var total: Int { converted + kept + ambiguousFixable + ambiguousKept + missed.count + wrong.count }
    }

    func testSeedCorpus() throws {
        let outcome = try replay(corpus: "seed.tsv", decider: LayoutDecider())
        print(report(outcome, title: "seed.tsv"))

        // Changing text the user typed correctly is the worst failure: it
        // erodes trust. Missing a conversion only costs a hotkey press.
        XCTAssertEqual(outcome.wrong, [], "words changed that should have been left alone")
        XCTAssertLessThanOrEqual(outcome.missed.count, outcome.total / 20, "more than 5% of mistyped words missed")
    }

    /// Words the lexicon has never seen (inflections, rare words) are judged by
    /// the character model alone. Hold every 10th word out of the lexicon, then
    /// type each held-out word both correctly and in the wrong layout, across a
    /// range of `minimumGain` thresholds. The printed table is how the default
    /// threshold was chosen.
    func testHeldOutWordsCalibration() throws {
        func load(_ name: String) throws -> [(word: String, count: Int)] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("LayoutBuddy/Resources/\(name)")
            return LanguageModel.parseWordList(try String(contentsOf: url, encoding: .utf8))
        }
        func split(_ entries: [(word: String, count: Int)]) -> (train: [(word: String, count: Int)], test: [String]) {
            var train: [(word: String, count: Int)] = [], test: [String] = []
            for (i, e) in entries.enumerated() {
                if i % 10 == 5 { if e.word.count >= 3 { test.append(e.word) } } else { train.append(e) }
            }
            return (train, test)
        }
        let en = split(try load("words-en.txt")), uk = split(try load("words-uk.txt"))
        var decider = LayoutDecider(english: LanguageModel(alphabet: LanguageModel.englishAlphabet, entries: en.train),
                                    ukrainian: LanguageModel(alphabet: LanguageModel.ukrainianAlphabet, entries: uk.train))

        var lines = ["── Held-out words: \(en.test.count) en, \(uk.test.count) uk (each typed right and wrong) ──",
                     "  minGain   changed-correct   missed-mistyped"]
        var atDefault = (wrong: 0.0, missed: 0.0)
        for threshold in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            decider.minimumGain = threshold
            var wrong = 0, missed = 0, cases = 0
            for (words, script, other) in [(en.test, Script.latin, Script.cyrillic), (uk.test, .cyrillic, .latin)] {
                for word in words {
                    cases += 1
                    if case .convert = decider.decide(word, typedIn: script) { wrong += 1 }
                    let mistyped = KeyboardLayoutConverter.convert(word, from: script, to: other)
                    if case .convert(let fixed) = decider.decide(mistyped, typedIn: other), fixed == word {} else { missed += 1 }
                }
            }
            let rates = (wrong: 100 * Double(wrong) / Double(cases), missed: 100 * Double(missed) / Double(cases))
            if threshold == LayoutDecider().minimumGain { atDefault = rates }
            lines.append(String(format: "  %5.2f     %6.2f%%           %6.2f%%%@", threshold, rates.wrong, rates.missed,
                                threshold == LayoutDecider().minimumGain ? "   ← default" : ""))
        }
        print(lines.joined(separator: "\n"))

        XCTAssertLessThan(atDefault.wrong, 0.1, "default threshold changes too many correctly typed unknown words")
        XCTAssertLessThan(atDefault.missed, 10.0, "default threshold misses too many mistyped unknown words")
    }

    /// Names, jargon, slang and typos: the words most likely to be wrongly
    /// "corrected" because no lexicon contains them.
    func testHardCorpus() throws {
        let outcome = try replay(corpus: "hard.tsv", decider: LayoutDecider())
        print(report(outcome, title: "hard.tsv"))
        XCTAssertEqual(outcome.wrong, [], "words changed that should have been left alone")
    }

    // MARK: - Replay

    private func replay(corpus name: String, decider: LayoutDecider) throws -> Outcome {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Corpus").appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        var outcome = Outcome()
        for (number, line) in text.split(separator: "\n").enumerated() where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            XCTAssertEqual(columns.count, 2, "\(name):\(number + 1) needs typed<TAB>intended")
            guard columns.count == 2 else { continue }
            let typed = Array(columns[0]), intended = Array(columns[1])
            XCTAssertEqual(typed.count, intended.count, "\(name):\(number + 1) columns differ in length")
            guard typed.count == intended.count else { continue }

            for (range, script) in tokens(in: typed) {
                let token = String(typed[range])
                let (core, _, decision) = decider.decide(token: token, typedIn: script)
                let coreRange = range.lowerBound..<(range.lowerBound + core.count)
                let meant = String(intended[coreRange])
                let mistyped = meant != core
                let label = "\(core) → \(meant)  [\(line.split(separator: "\t")[1])]"

                switch decision {
                case .keep:
                    if mistyped { outcome.missed.append(label) } else { outcome.kept += 1 }
                case .ambiguous:
                    if mistyped { outcome.ambiguousFixable += 1 } else { outcome.ambiguousKept += 1 }
                case .convert(let converted):
                    if mistyped && converted == meant { outcome.converted += 1 }
                    else { outcome.wrong.append("\(core) ⇒ \(converted)  (meant \(meant))  [\(columns[1])]") }
                }
            }
        }
        return outcome
    }

    /// Splits typed text into words the way the key handler buffers them:
    /// letters of one script, plus — after or before Latin letters — the Latin
    /// punctuation keys that are letters on the Ukrainian layout.
    private func tokens(in chars: [Character]) -> [(Range<Int>, Script)] {
        let parser = WordParser()
        func isLatin(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy(parser.isLatinLetter) }
        func isCyrillic(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy(parser.isCyrillicLetter) }
        func isMapped(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy(parser.isMappedLatinPunctuation) }

        var result: [(Range<Int>, Script)] = []
        var start: Int?
        var script: Script?
        func flush(_ end: Int) {
            if let s = start, let sc = script, s < end { result.append((s..<end, sc)) }
            start = nil; script = nil
        }
        for (i, c) in chars.enumerated() {
            let charScript: Script?
            if isLatin(c) { charScript = .latin }
            else if isCyrillic(c) { charScript = .cyrillic }
            else if isMapped(c), script == .latin || (script == nil && chars[(i + 1)...].first.map(isLatin) == true) {
                charScript = .latin
            } else { charScript = nil }

            guard let cs = charScript else { flush(i); continue }
            if let current = script, current != cs { flush(i) }
            if start == nil { start = i; script = cs }
        }
        flush(chars.count)
        return result
    }

    private func report(_ o: Outcome, title: String) -> String {
        func pct(_ n: Int) -> String { String(format: "%.1f%%", 100 * Double(n) / Double(max(1, o.total))) }
        var lines = [
            "── Replay: \(title) — \(o.total) words ──",
            "  converted correctly     \(o.converted)",
            "  left alone correctly    \(o.kept)",
            "  ambiguous (hotkey) — was mistyped \(o.ambiguousFixable), was fine \(o.ambiguousKept)",
            "  MISSED                  \(o.missed.count) (\(pct(o.missed.count)))",
            "  WRONGLY CHANGED         \(o.wrong.count) (\(pct(o.wrong.count)))",
        ]
        lines += o.missed.map { "    missed: \($0)" }
        lines += o.wrong.map { "    wrong:  \($0)" }
        return lines.joined(separator: "\n")
    }
}
