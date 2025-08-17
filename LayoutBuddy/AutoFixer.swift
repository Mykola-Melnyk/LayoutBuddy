import Foundation

/// Determines when a typed word should be converted to the other keyboard layout.
final class AutoFixer {
    private let mapper: KeyboardLayoutMapper
    private let spellChecker: SpellCheckerService

    init(mapper: KeyboardLayoutMapper, spellChecker: SpellCheckerService) {
        self.mapper = mapper
        self.spellChecker = spellChecker
    }

    /// Attempts to convert the provided word if it appears misspelled in the
    /// current language but correct in the opposite one. Returns the converted
    /// word and the target language prefix on success, or `nil` if no change is
    /// needed.
    func autoFix(word: String, currentLangPrefix: String) -> (converted: String, targetLang: String)? {
        let other = currentLangPrefix == "en" ? "uk" : "en"

        guard let curLang = spellChecker.bestLanguage(for: currentLangPrefix),
              let otherLang = spellChecker.bestLanguage(for: other) else {
            return nil
        }

        let curOK = spellChecker.isCorrect(word, language: curLang)
        let converted = mapper.convert(word, from: currentLangPrefix, to: other)
        let otherOK = spellChecker.isCorrect(converted, language: otherLang)

        if !curOK && otherOK {
            return (converted, other)
        }
        return nil
    }
}

