import Cocoa
import Carbon

/// Provides access to keyboard input sources and layout switching.
final class KeyboardLayoutManager {
    private let preferences: LayoutPreferences

    // The selectable-layouts list and its per-id index only change when the
    // user enables/disables input sources, but `listSelectableKeyboardLayouts`
    // and `inputSourceInfo(for:)` are called on the event-tap hot path (every
    // keystroke). Cache the result and invalidate it on the relevant TIS
    // notifications. Guarded by a lock because reads come from the event-tap
    // thread while invalidation arrives on the notification thread.
    private let cacheLock = NSLock()
    private var allLayoutsCache: [InputSourceInfo]?
    private var infoCache: [String: InputSourceInfo] = [:]
    private var observerTokens: [NSObjectProtocol] = []

    init(preferences: LayoutPreferences) {
        self.preferences = preferences

        let center = DistributedNotificationCenter.default()
        let rawNames: [CFString?] = [
            kTISNotifyEnabledKeyboardInputSourcesChanged,
            kTISNotifySelectedKeyboardInputSourceChanged
        ]
        for raw in rawNames.compactMap({ $0 as String? }) {
            let token = center.addObserver(
                forName: Notification.Name(raw),
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.invalidateCaches() }
            observerTokens.append(token)
        }
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        observerTokens.forEach(center.removeObserver(_:))
    }

    private func invalidateCaches() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        allLayoutsCache = nil
        infoCache.removeAll(keepingCapacity: true)
    }

    // MARK: - Input Source Info
    struct InputSourceInfo {
        let id: String
        let name: String
        let languages: [String]
    }

    func listSelectableKeyboardLayouts() -> [InputSourceInfo] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = allLayoutsCache { return cached }
        let infos = fetchSelectableKeyboardLayouts()
        allLayoutsCache = infos
        infoCache = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return infos
    }

    private func fetchSelectableKeyboardLayouts() -> [InputSourceInfo] {
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
        cacheLock.lock()
        if allLayoutsCache != nil {
            let hit = infoCache[id]
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        // Cold cache: populate it, then read the index under the lock again.
        _ = listSelectableKeyboardLayouts()
        cacheLock.lock(); defer { cacheLock.unlock() }
        return infoCache[id]
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
