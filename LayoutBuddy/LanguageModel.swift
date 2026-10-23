import Foundation

/// In-process statistics for one language: a word-frequency lexicon plus a
/// character-trigram model trained from it. Everything is in memory and a
/// lookup costs microseconds, so it is safe to consult from the event tap —
/// unlike `NSSpellChecker`, which round-trips to a separate service.
///
/// The trigram model is what lets the decider judge words that aren't in the
/// lexicon (inflected forms, rare words, names): "how much does this letter
/// sequence look like language X?"
final class LanguageModel {

    /// Letters the model knows. Anything else (digits, punctuation, the other
    /// script) is scored as a never-seen symbol — a strong signal by itself.
    let alphabet: [Character]

    private let logFrequency: [String: Double]
    private let symbolIndex: [Character: Int]
    private let symbolCount: Int          // alphabet + start + end + unknown
    private let startSymbol: Int
    private let endSymbol: Int
    private let unknownSymbol: Int

    private var unigram: [Double]
    private var bigram: [Double]
    private var trigram: [Double]
    private var bigramContext: [Double]   // count(a, ·)
    private var trigramContext: [Double]  // count(a, b, ·)
    private var unigramTotal = 0.0

    // Interpolation weights for trigram / bigram / unigram / uniform.
    private static let weights = (tri: 0.6, bi: 0.25, uni: 0.1, uniform: 0.05)

    /// - Parameter entries: (lowercased word, corpus count) pairs.
    init(alphabet: String, entries: [(word: String, count: Int)]) {
        self.alphabet = Array(alphabet)
        var index: [Character: Int] = [:]
        for (i, ch) in self.alphabet.enumerated() { index[ch] = i }
        symbolIndex = index
        startSymbol = self.alphabet.count
        endSymbol = startSymbol + 1
        unknownSymbol = startSymbol + 2
        symbolCount = startSymbol + 3

        let k = symbolCount
        unigram = Array(repeating: 0, count: k)
        bigram = Array(repeating: 0, count: k * k)
        trigram = Array(repeating: 0, count: k * k * k)
        bigramContext = Array(repeating: 0, count: k)
        trigramContext = Array(repeating: 0, count: k * k)

        let total = Double(entries.reduce(0) { $0 + $1.count })
        var frequencies: [String: Double] = [:]
        frequencies.reserveCapacity(entries.count)
        for entry in entries where entry.count > 0 {
            frequencies[entry.word] = log(Double(entry.count) / total)
        }
        logFrequency = frequencies
        for entry in entries where entry.count > 0 {
            // Weight by log-frequency rather than raw count: common words
            // shouldn't drown out the shapes of the long tail.
            train(entry.word, weight: 1 + log10(Double(entry.count)))
        }
    }

    // MARK: - Queries

    /// Natural-log relative frequency of `word` (lowercased), or nil when the
    /// lexicon doesn't contain it.
    func frequency(of word: String) -> Double? {
        logFrequency[word.lowercased()]
    }

    func contains(_ word: String) -> Bool {
        logFrequency[word.lowercased()] != nil
    }

    /// Mean log-probability per symbol of `word` under the trigram model,
    /// including the end-of-word transition. Higher is more language-like;
    /// typical words land around -2, keyboard-layout garbage well below -4.
    func characterScore(of word: String) -> Double {
        let symbols = word.lowercased().map { symbolIndex[$0] ?? unknownSymbol } + [endSymbol]
        var a = startSymbol, b = startSymbol
        var sum = 0.0
        for c in symbols {
            sum += log(probability(c, after: a, b))
            a = b; b = c
        }
        return sum / Double(symbols.count)
    }

    // MARK: - Training

    private func train(_ word: String, weight: Double) {
        let symbols = word.map { symbolIndex[$0] ?? unknownSymbol } + [endSymbol]
        let k = symbolCount
        var a = startSymbol, b = startSymbol
        for c in symbols {
            unigram[c] += weight
            unigramTotal += weight
            bigram[b * k + c] += weight
            bigramContext[b] += weight
            trigram[(a * k + b) * k + c] += weight
            trigramContext[a * k + b] += weight
            a = b; b = c
        }
    }

    private func probability(_ c: Int, after a: Int, _ b: Int) -> Double {
        let k = symbolCount
        let w = Self.weights
        var p = w.uniform / Double(k)
        if unigramTotal > 0 { p += w.uni * unigram[c] / unigramTotal }
        let biContext = bigramContext[b]
        if biContext > 0 { p += w.bi * bigram[b * k + c] / biContext }
        let triContext = trigramContext[a * k + b]
        if triContext > 0 { p += w.tri * trigram[(a * k + b) * k + c] / triContext }
        return p
    }
}

// MARK: - Bundled models

extension LanguageModel {
    static let englishAlphabet = "abcdefghijklmnopqrstuvwxyz"
    static let ukrainianAlphabet = "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя"

    /// Loaded once, on first use, from `words-en.txt` / `words-uk.txt`.
    static let english = bundled(resource: "words-en", alphabet: englishAlphabet)
    static let ukrainian = bundled(resource: "words-uk", alphabet: ukrainianAlphabet)

    private static func bundled(resource: String, alphabet: String) -> LanguageModel {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("missing bundled word list \(resource).txt")
            return LanguageModel(alphabet: alphabet, entries: [])
        }
        return LanguageModel(alphabet: alphabet, entries: parseWordList(text))
    }

    /// Parses `word<TAB>count` lines; `#` starts a comment line.
    static func parseWordList(_ text: String) -> [(word: String, count: Int)] {
        var entries: [(word: String, count: Int)] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let count = Int(parts[1]) else { continue }
            entries.append((String(parts[0]), count))
        }
        return entries
    }
}
