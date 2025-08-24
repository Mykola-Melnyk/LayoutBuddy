import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Protocols

protocol InputLayoutManaging {
    func listSelectableKeyboardLayouts() -> [KeyboardLayoutManager.InputSourceInfo]
    func inputSourceInfo(for id: String) -> KeyboardLayoutManager.InputSourceInfo?
    func isLanguage(id: String, hasPrefix prefix: String) -> Bool
    func currentInputSourceID() -> String
    func switchLayout(to id: String)
    func toggleLayout()
}

protocol PreferencesStoring: AnyObject {
    var primaryID: String { get set }
    var secondaryID: String { get set }
    func autoDetectSecondaryID() -> String
}

protocol WordParsingProtocol: AnyObject {
    var buffer: String { get }
    func isMappedLatinPunctuation(_ s: UnicodeScalar) -> Bool
    func splitTrailingMapped(_ s: String) -> (core: String, trailingCount: Int)
    func containsSuspiciousMapped(_ s: String) -> Bool
    func isWordInternal(_ s: UnicodeScalar) -> Bool
    func isBoundary(_ s: UnicodeScalar) -> Bool
    func isLatinLetter(_ s: UnicodeScalar) -> Bool
    func isCyrillicLetter(_ s: UnicodeScalar) -> Bool
    func append(character: UnicodeScalar)
    func removeLast()
    func completeWord() -> String?
    func clear()
    // testing hooks used by AppCoordinator tests
    func test_setBuffer(_ text: String)
    func test_getBuffer() -> String
}

protocol SpellChecking {
    func bestLanguage(prefix: String) -> String?
    func isSpelledCorrect(_ word: String, language: String) -> Bool
}

protocol LayoutConverting {
    func convert(_ word: String, from src: String, to dst: String) -> String
}

// MARK: - Implementations

#if canImport(AppKit)
final class NSSpellCheckerService: SpellChecking {
    private let spellDocTag: Int = NSSpellChecker.uniqueSpellDocumentTag()

    func bestLanguage(prefix: String) -> String? {
        NSSpellChecker.shared.availableLanguages.first { $0.hasPrefix(prefix) }
    }

    func isSpelledCorrect(_ word: String, language: String) -> Bool {
        let miss = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: spellDocTag, wordCount: nil
        )
        return miss.location == NSNotFound
    }
}
#endif

final class PositionLayoutConverter: LayoutConverting {
    func convert(_ word: String, from src: String, to dst: String) -> String {
        if src == "en", dst == "uk" { return mapWord(word, using: en2uk) }
        if src == "uk", dst == "en" { return mapWord(word, using: uk2en) }
        return word
    }

    private func mapWord(_ word: String, using table: [Character: String]) -> String {
        var out = ""
        for ch in word {
            let isUpper = ch.isUppercase
            let lower = Character(ch.lowercased())
            if let mapped = table[lower] {
                out += isUpper ? mapped.uppercased() : mapped
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private let en2uk: [Character: String] = [
        "q":"й","w":"ц","e":"у","r":"к","t":"е","y":"н","u":"г","i":"ш","o":"щ","p":"з","[":"х","]":"ї",
        "a":"ф","s":"і","d":"в","f":"а","g":"п","h":"р","j":"о","k":"л","l":"д",";":"ж","'":"є",
        "z":"я","x":"ч","c":"с","v":"м","b":"и","n":"т","m":"ь",",":"б",".":"ю","/":"."
    ]

    private lazy var uk2en: [Character: String] = {
        var rev: [Character: String] = [:]
        for (k,v) in en2uk { for ch in v { rev[ch] = String(k) } }
        rev["’"] = "'" // apostrophe variant
        return rev
    }()
}
