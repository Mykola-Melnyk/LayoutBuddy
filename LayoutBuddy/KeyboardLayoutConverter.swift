import Foundation

enum KeyboardLayoutConverter {
    static func convert(_ word: String, from sourceLanguage: String, to destinationLanguage: String) -> String {
        if sourceLanguage == "en", destinationLanguage == "uk" {
            return mapWord(word, using: enToUkrainian)
        }
        if sourceLanguage == "uk", destinationLanguage == "en" {
            return mapWord(word, using: ukrainianToEnglish)
        }
        return word
    }

    private static func mapWord(_ word: String, using table: [Character: String]) -> String {
        var output = ""
        for character in word {
            let isUppercase = character.isUppercase
            let lowercased = Character(character.lowercased())
            if let mapped = table[lowercased] {
                output += isUppercase ? mapped.uppercased() : mapped
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static let enToUkrainian: [Character: String] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ї",
        "a": "ф", "s": "і", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л", "l": "д", ";": "ж", "'": "є",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь", ",": "б", ".": "ю", "/": "."
    ]

    private static let ukrainianToEnglish: [Character: String] = {
        var reversed: [Character: String] = [:]
        for (key, value) in enToUkrainian {
            for character in value {
                reversed[character] = String(key)
            }
        }
        reversed["’"] = "'"
        return reversed
    }()
}
