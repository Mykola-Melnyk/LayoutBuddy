import Foundation

/// Parses a stream of characters into words.
/// Maintains an internal buffer and exposes helper methods
/// used by consumers such as the key handler.
final class WordParser {
    private(set) var wordBuffer = ""
    /// Read-only view of the internal buffer for consumers like `AppCoordinator`.
    var buffer: String { wordBuffer }

    // MARK: - Parsing helpers

    private let letterLikePunctScalars = Set("[];',.".unicodeScalars)
    func isMappedLatinPunctuation(_ s: UnicodeScalar) -> Bool {
        letterLikePunctScalars.contains(s)
    }

    private let trailingMappedScalars = Set(".,;".unicodeScalars)
    func splitTrailingMapped(_ s: String) -> (core: String, trailingCount: Int) {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, trailingMappedScalars.contains(last) {
            scalars.removeLast()
        }
        let core = String(String.UnicodeScalarView(scalars))
        return (core, s.count - core.count)
    }

    private let suspicionMappedScalars = Set("[];,. ".unicodeScalars).subtracting(Set("'".unicodeScalars))
    func containsSuspiciousMapped(_ s: String) -> Bool {
        s.unicodeScalars.contains { suspicionMappedScalars.contains($0) }
    }

    private let wordInternalScalars = Set("'’-".unicodeScalars)
    func isWordInternal(_ s: UnicodeScalar) -> Bool { wordInternalScalars.contains(s) }

    func isBoundary(_ s: UnicodeScalar) -> Bool {
        if isWordInternal(s) { return false }
        if CharacterSet.whitespacesAndNewlines.contains(s) { return true }
        let punct = ".,;:!?()[]{}<>/\\\"“”‘’—–_|@#€$%^&*+=`~"
        return punct.unicodeScalars.contains(s)
    }

    func isLatinLetter(_ s: UnicodeScalar) -> Bool {
        ((0x41...0x5A).contains(s.value)) || ((0x61...0x7A).contains(s.value))
    }
    func isCyrillicLetter(_ s: UnicodeScalar) -> Bool {
        (0x0400...0x04FF).contains(s.value) ||
        (0x0500...0x052F).contains(s.value) ||
        (0x2DE0...0x2DFF).contains(s.value) ||
        (0xA640...0xA69F).contains(s.value)
    }

    // MARK: - Buffer manipulation

    func append(character: UnicodeScalar) {
        wordBuffer.unicodeScalars.append(character)
    }

    func removeLast() {
        guard !wordBuffer.isEmpty else { return }
        wordBuffer.unicodeScalars.removeLast()
    }

    /// Returns the current word and clears the buffer.
    func completeWord() -> String? {
        guard !wordBuffer.isEmpty else { return nil }
        let word = wordBuffer
        wordBuffer = ""
        return word
    }

    /// Clears the internal buffer.
    func clear() {
        wordBuffer = ""
    }

    // MARK: - Testing helpers
    func test_setBuffer(_ text: String) { wordBuffer = text }
    func test_getBuffer() -> String { wordBuffer }
}

