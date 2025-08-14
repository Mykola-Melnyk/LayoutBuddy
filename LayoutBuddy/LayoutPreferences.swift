import Cocoa
import Carbon

/// Handles storage and discovery of keyboard layout preferences.
final class LayoutPreferences {
    private let defaults: UserDefaults
    private let kPrimaryIDKey = "PrimaryInputSourceID"
    private let kSecondaryIDKey = "SecondaryInputSourceID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Exposed layout identifiers
    var primaryID: String {
        get { defaults.string(forKey: kPrimaryIDKey) ?? autoDetectPrimaryID() }
        set { defaults.set(newValue, forKey: kPrimaryIDKey) }
    }

    var secondaryID: String {
        get { defaults.string(forKey: kSecondaryIDKey) ?? autoDetectSecondaryID() }
        set { defaults.set(newValue, forKey: kSecondaryIDKey) }
    }

    // MARK: - Input Source Info
    struct InputSourceInfo {
        let id: String
        let name: String
        let languages: [String]
    }

    func listSelectableKeyboardLayouts() -> [InputSourceInfo] {
        let query: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as CFString,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        guard let list = TISCreateInputSourceList(query as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }

        let infos = list.compactMap { src -> InputSourceInfo? in
            let id = (tisProperty(src, kTISPropertyInputSourceID) as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let name = (tisProperty(src, kTISPropertyLocalizedName) as? String) ?? id
            let langs = (tisProperty(src, kTISPropertyInputSourceLanguages) as? [String]) ?? []
            return InputSourceInfo(id: id, name: name, languages: langs)
        }
        return infos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func inputSourceInfo(for id: String) -> InputSourceInfo? {
        listSelectableKeyboardLayouts().first { $0.id == id }
    }

    func currentInputSourceID() -> String {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
        return (tisProperty(cur, kTISPropertyInputSourceID) as? String) ?? ""
    }

    func isLanguage(id: String, hasPrefix prefix: String) -> Bool {
        inputSourceInfo(for: id)?.languages.contains { $0.hasPrefix(prefix) } ?? false
    }

    // MARK: - Auto-detection
    func autoDetectPrimaryID() -> String {
        let current = currentInputSourceID()
        if !current.isEmpty { return current }
        let all = listSelectableKeyboardLayouts()
        if let us = all.first(where: { $0.id == "com.apple.keylayout.US" }) { return us.id }
        if let abc = all.first(where: { $0.id == "com.apple.keylayout.ABC" }) { return abc.id }
        return all.first?.id ?? "com.apple.keylayout.US"
    }

    func autoDetectSecondaryID() -> String {
        let primary = primaryID
        let all = listSelectableKeyboardLayouts()
        let primaryLang = all.first(where: { $0.id == primary })?.languages.first ?? ""
        let desiredPrefix = primaryLang.hasPrefix("en") ? "uk" : "en"
        if let differentLang = all.first(where: {
            $0.languages.contains(where: { $0.hasPrefix(desiredPrefix) }) && $0.id != primary
        }) {
            return differentLang.id
        }
        return all.first(where: { $0.id != primary })?.id ?? primary
    }

    // MARK: - Private
    private func tisProperty(_ src: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }
}
