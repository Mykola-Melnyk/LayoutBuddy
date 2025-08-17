import Cocoa

/// Thin wrapper around `NSSpellChecker` for testability and injection.
/// `NSSpellChecker` must be accessed on the main thread, but tests may invoke
/// this service from background threads. To avoid crashes, the actual calls are
/// synchronised back to the main queue as needed.
final class SpellCheckerService {
    private let spellDocTag: Int = NSSpellChecker.uniqueSpellDocumentTag()

    // Executes work on the main queue if we're currently on a background thread.
    private func performOnMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        var result: T!
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            result = work()
            sema.signal()
        }
        sema.wait()
        return result
    }

    /// Finds the best available language that matches the prefix, e.g. "en" or "uk".
    func bestLanguage(for prefix: String) -> String? {
        performOnMain {
            NSSpellChecker.shared.availableLanguages.first { $0.hasPrefix(prefix) }
        }
    }

    /// Returns `true` if the given word is spelled correctly in the provided language.
    func isCorrect(_ word: String, language: String) -> Bool {
        performOnMain {
            let miss = NSSpellChecker.shared.checkSpelling(
                of: word,
                startingAt: 0,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: self.spellDocTag,
                wordCount: nil
            )
            return miss.location == NSNotFound
        }
    }
}

