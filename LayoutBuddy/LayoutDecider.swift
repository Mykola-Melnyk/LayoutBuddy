import Foundation

/// Decides whether a just-typed word was typed in the wrong keyboard layout.
/// Pure and in-process (lexicon lookups + character-trigram scores), so it is
/// cheap enough to run inside the event tap and fully unit-testable.
struct LayoutDecider {
    typealias Script = KeyboardLayoutConverter.Script

    enum Decision: Equatable {
        /// Leave the word as typed.
        case keep
        /// The word was clearly typed in the wrong layout; replace it.
        case convert(String)
        /// Both readings are plausible: leave it, but let the hotkey fix it.
        case ambiguous(String)
    }

    var english: LanguageModel = .english
    var ukrainian: LanguageModel = .ukrainian
    /// The user's own word lists, which count as known words.
    var isUserWord: (String, Script) -> Bool = { _, _ in false }
    /// How much more language-like (mean log-probability per letter) the
    /// converted word must be before an unknown word is converted. Calibrated
    /// with `ReplayCorpusTests`: at 1.0, 0.02% of correctly typed unseen words
    /// get changed and ~6% of mistyped ones are missed; 0.5 starts changing
    /// jargon like "lgtm".
    var minimumGain: Double = 1.0

    /// Keys that type punctuation on the Latin layout but letters (х ї ж б ю)
    /// on the Ukrainian one. Inside a Latin word they can't be English.
    private static let ukrainianLetterKeys = Set<Character>("[];,.")
    private static let trailingPunctuation = Set<Character>(".,;")
    private static let contractionSuffixes: Set<String> = ["'s", "'t", "'re", "'ve", "'ll", "'d", "'m"]
    private static let singleLetterWords: [Script: Set<String>] = [
        .latin: ["a", "i"],
        .cyrillic: ["а", "б", "в", "є", "ж", "з", "і", "й", "о", "у", "я"],
    ]

    /// Decides a whole typed token. Trailing "." "," ";" are ambiguous on the
    /// Latin layout: punctuation, or the letters ю б ж typed in the wrong
    /// layout ("lzre." is "дякую"). Prefer the letter reading when it yields a
    /// known word; otherwise treat them as punctuation and decide the core.
    func decide(token: String, typedIn source: Script) -> (core: String, trailing: String, decision: Decision) {
        let core = String(token.reversed().drop(while: Self.trailingPunctuation.contains).reversed())
        let trailing = String(token.dropFirst(core.count))
        if !trailing.isEmpty, !core.isEmpty, source == .latin {
            let whole = decide(token, typedIn: source)
            if case .convert(let converted) = whole, knows(converted, in: .cyrillic) {
                return (token, "", whole)
            }
        }
        return (core, trailing, decide(core, typedIn: source))
    }

    /// - Parameters:
    ///   - word: the typed word, trailing punctuation already removed.
    ///   - source: the script it was typed in.
    func decide(_ word: String, typedIn source: Script) -> Decision {
        let target: Script = source == .latin ? .cyrillic : .latin
        let converted = KeyboardLayoutConverter.convert(word, from: source, to: target)
        guard !word.isEmpty, !converted.isEmpty, converted != word else { return .keep }

        // getValue, iPhone, McDonald: identifiers and brands, not layout slips.
        if hasInnerCapital(word) { return .keep }

        if source == .latin, word.contains(where: Self.ukrainianLetterKeys.contains) {
            return converted.unicodeScalars.allSatisfy(Self.isCyrillicLetter) ? .convert(converted) : .keep
        }

        switch (knows(word, in: source), knows(converted, in: target)) {
        case (true, true):
            return .ambiguous(converted)
        case (true, false):
            return .keep
        case (false, true):
            // A lone capital ("Plan B") is too often a label to change silently.
            if word.count == 1, word.first?.isUppercase == true { return .ambiguous(converted) }
            // An unknown but natural-looking word that happens to convert into
            // a rare lexicon entry ("legs" → "дупі") is a coincidence, not a slip.
            if word.count > 1, gain(word, from: source, to: converted, in: target) < 0 { return .ambiguous(converted) }
            return .convert(converted)
        case (false, false):
            // Too short, or an acronym: letter statistics aren't reliable here.
            guard word.count >= 3, !isAllCaps(word) else { return .keep }
            // Three letters carry little evidence ("лук" ⇄ "ker"): demand more.
            let required = word.count == 3 ? 2 * minimumGain : minimumGain
            return gain(word, from: source, to: converted, in: target) >= required ? .convert(converted) : .keep
        }
    }

    /// Per-letter log-probability advantage of the converted reading.
    func gain(_ word: String, from source: Script, to converted: String, in target: Script) -> Double {
        model(for: target).characterScore(of: converted) - model(for: source).characterScore(of: word)
    }

    // MARK: - Helpers

    private func model(for script: Script) -> LanguageModel {
        script == .latin ? english : ukrainian
    }

    private func knows(_ word: String, in script: Script) -> Bool {
        if isUserWord(word, script) { return true }
        let lower = word.lowercased()
        if lower.count == 1 { return Self.singleLetterWords[script]?.contains(lower) ?? false }
        let model = model(for: script)
        if model.contains(lower) { return true }
        // The lexicon splits "don't" into "don" + "'t".
        if script == .latin, let apostrophe = lower.firstIndex(of: "'") {
            return Self.contractionSuffixes.contains(String(lower[apostrophe...]))
                && model.contains(String(lower[..<apostrophe]))
        }
        return false
    }

    private func hasInnerCapital(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase) && !isAllCaps(word)
    }

    private func isAllCaps(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    private static func isCyrillicLetter(_ s: UnicodeScalar) -> Bool {
        (0x0400...0x04FF).contains(s.value)
    }
}
