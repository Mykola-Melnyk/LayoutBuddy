import Cocoa
import Carbon

/// Provides access to keyboard input sources and layout switching.
final class KeyboardLayoutManager {
    private let preferences: LayoutPreferences

    init(preferences: LayoutPreferences) {
        self.preferences = preferences
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

    func isLanguage(id: String, hasPrefix prefix: String) -> Bool {
        inputSourceInfo(for: id)?.languages.contains { $0.hasPrefix(prefix) } ?? false
    }

    func currentInputSourceID() -> String {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
        return (tisProperty(cur, kTISPropertyInputSourceID) as? String) ?? ""
    }

    // MARK: - Switching
    func toggleLayout() {
        let current = currentInputSourceID()
        let target = (current == preferences.secondaryID) ? preferences.primaryID : preferences.secondaryID
        switchLayout(to: target)
    }

    /// Switches the current keyboard layout to the specified input source ID.
    func switchLayout(to id: String) {
        switchToInputSource(id: id)
    }

    private func switchToInputSource(id: String) {
        let query: [CFString: Any] = [
            kTISPropertyInputSourceID: id,
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as CFString,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        if let list = TISCreateInputSourceList(query as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource],
           let target = list.first {
            TISEnableInputSource(target)
            TISSelectInputSource(target)
        }
    }

    // MARK: - Private
    private func tisProperty(_ src: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }
}
