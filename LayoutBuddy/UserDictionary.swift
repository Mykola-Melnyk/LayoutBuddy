import Combine
import Foundation

/// User-maintained word lists that augment the system spell-checker: a word
/// added here is treated as correctly spelled in that language, so the
/// converter won't wrongly "fix" it (e.g. add "Kyiv" to English, or a Ukrainian
/// slang word to Ukrainian).
///
/// Lookups (`contains`) happen on the event-tap thread, so the backing sets are
/// guarded by a lock; the `@Published` arrays are for the Settings UI and are
/// mutated on the main thread.
final class UserDictionary: ObservableObject {
    enum Language: String, CaseIterable, Identifiable {
        case english = "en"
        case ukrainian = "uk"
        var id: String { rawValue }
        var displayName: String { self == .english ? "English" : "Ukrainian" }
    }

    /// Sorted, human-readable word lists for the UI.
    @Published private(set) var english: [String] = []
    @Published private(set) var ukrainian: [String] = []

    private let defaults: UserDefaults
    private let storageKey = "UserDictionary"

    // Lowercased sets for fast, case-insensitive, thread-safe lookup.
    private let lock = NSLock()
    private var sets: [Language: Set<String>] = [.english: [], .ukrainian: []]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Lookup (any thread)

    /// True if `word` is in the list for the given spell-checker language prefix
    /// ("en"/"uk").
    func contains(_ word: String, languagePrefix: String) -> Bool {
        guard let language = Language(rawValue: languagePrefix) else { return false }
        let key = normalized(word)
        guard !key.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return sets[language]?.contains(key) ?? false
    }

    // MARK: - Editing (main thread)

    /// Adds a word to one or more languages. Returns the languages it was newly
    /// added to (empty if it was already present everywhere requested).
    @discardableResult
    func add(_ word: String, to languages: Set<Language>) -> Set<Language> {
        let key = normalized(word)
        guard !key.isEmpty else { return [] }
        var added: Set<Language> = []
        for language in languages where update(language, { $0.insert(key).inserted }) {
            added.insert(language)
        }
        if !added.isEmpty { publish(); save() }
        return added
    }

    func remove(_ word: String, from language: Language) {
        let key = normalized(word)
        guard update(language, { $0.remove(key) != nil }) else { return }
        publish(); save()
    }

    func words(for language: Language) -> [String] {
        language == .english ? english : ukrainian
    }

    // MARK: - Internals

    private func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Mutates a language's set under the lock; returns whether it changed.
    private func update(_ language: Language, _ mutate: (inout Set<String>) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var set = sets[language] ?? []
        let changed = mutate(&set)
        if changed { sets[language] = set }
        return changed
    }

    private func snapshot(_ language: Language) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (sets[language] ?? []).sorted()
    }

    private func publish() {
        let en = snapshot(.english)
        let uk = snapshot(.ukrainian)
        let apply = { self.english = en; self.ukrainian = uk }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func save() {
        lock.lock()
        let payload = [Language.english.rawValue: Array(sets[.english] ?? []),
                       Language.ukrainian.rawValue: Array(sets[.ukrainian] ?? [])]
        lock.unlock()
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            publish(); return
        }
        lock.lock()
        sets[.english] = Set((payload[Language.english.rawValue] ?? []).map(normalized))
        sets[.ukrainian] = Set((payload[Language.ukrainian.rawValue] ?? []).map(normalized))
        lock.unlock()
        publish()
    }
}
