import Cocoa

/// Thin wrapper around `NSSpellChecker` for testability and injection.
final class SpellCheckerService {
    private let spellDocTag: Int = NSSpellChecker.uniqueSpellDocumentTag()

    /// Finds the best available language that matches the prefix, e.g. "en" or "uk".
    func bestLanguage(for prefix: String) -> String? {
        NSSpellChecker.shared.availableLanguages.first { $0.hasPrefix(prefix) }
    }

    /// Returns `true` if the given word is spelled correctly in the provided language.
    func isCorrect(_ word: String, language: String) -> Bool {
        let miss = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: spellDocTag,
            wordCount: nil
        )
        return miss.location == NSNotFound
    }
}

