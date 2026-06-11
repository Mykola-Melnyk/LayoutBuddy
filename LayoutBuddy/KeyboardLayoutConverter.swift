import Foundation

/// Maps text typed on one keyboard layout to the characters the same physical
/// keys would produce on another layout — used to repair text that was typed
/// with the wrong layout active.
enum KeyboardLayoutConverter {

    /// A keyboard layout we can convert between, identified by its
    /// spell-checker / input-source language prefix.
    enum Script {
        case latin      // "en"
        case cyrillic   // "uk"

        init?(languagePrefix: String) {
            switch languagePrefix {
            case "en": self = .latin
            case "uk": self = .cyrillic
            default:   return nil
            }
        }
    }

    /// Strongly-typed entry point. Adding a new layout pair is a matter of
    /// extending `keyPairs` and this switch — no other call site changes.
    static func convert(_ word: String, from source: Script, to destination: Script) -> String {
        guard source != destination else { return word }
        switch (source, destination) {
        case (.latin, .cyrillic): return mapWord(word, using: latinToCyrillic)
        case (.cyrillic, .latin): return mapWord(word, using: cyrillicToLatin)
        default:                  return word
        }
    }

    /// Convenience overload for call sites that thread spell-checker language
    /// codes ("en"/"uk"). Returns the word unchanged for unsupported pairs.
    static func convert(_ word: String, from sourceLanguage: String, to destinationLanguage: String) -> String {
        guard let from = Script(languagePrefix: sourceLanguage),
              let to = Script(languagePrefix: destinationLanguage) else { return word }
        return convert(word, from: from, to: to)
    }

    private static func mapWord(_ word: String, using table: [Character: String]) -> String {
        var output = ""
        output.reserveCapacity(word.count)
        for character in word {
            // `lowercased()` can produce more than one scalar; take the first
            // grapheme defensively so arbitrary input (e.g. clipboard text)
            // can never trap `Character.init`.
            guard let lowered = character.lowercased().first else {
                output.append(character)
                continue
            }
            if let mapped = table[lowered] {
                output += character.isUppercase ? mapped.uppercased() : mapped
            } else {
                output.append(character)
            }
        }
        return output
    }

    // MARK: - Mapping source of truth

    /// Physical-key correspondence between a US (ANSI) Latin layout and the
    /// Ukrainian (ЙЦУКЕН) layout, expressed once as `(latinKey, cyrillicKey)`
    /// pairs. Both direction tables are derived from this list so they can
    /// never drift out of sync.
    ///
    /// Note: `\` → `ґ` follows the Ukrainian-PC layout convention; on the
    /// stock macOS "Ukrainian" layout `ґ` sits elsewhere. Adjust here if you
    /// standardise on a different layout.
    private static let keyPairs: [(latin: Character, cyrillic: Character)] = [
        ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"), ("y", "н"),
        ("u", "г"), ("i", "ш"), ("o", "щ"), ("p", "з"), ("[", "х"), ("]", "ї"),
        ("a", "ф"), ("s", "і"), ("d", "в"), ("f", "а"), ("g", "п"), ("h", "р"),
        ("j", "о"), ("k", "л"), ("l", "д"), (";", "ж"), ("'", "є"),
        ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"), ("n", "т"),
        ("m", "ь"), (",", "б"), (".", "ю"), ("/", "."), ("\\", "ґ"),
    ]

    private static let latinToCyrillic: [Character: String] = {
        var map: [Character: String] = [:]
        for pair in keyPairs { map[pair.latin] = String(pair.cyrillic) }
        return map
    }()

    private static let cyrillicToLatin: [Character: String] = {
        var map: [Character: String] = [:]
        for pair in keyPairs { map[pair.cyrillic] = String(pair.latin) }
        // The typographic apostrophe that appears literally inside Ukrainian
        // words (e.g. "п'ять") maps back to a straight quote.
        map["’"] = "'"
        return map
    }()
}
