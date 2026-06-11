import Cocoa
import Carbon

/// Provides access to keyboard input sources and layout switching.
final class KeyboardLayoutManager {
    private let preferences: LayoutPreferences
    private let provider: InputSourceProviding

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

    init(preferences: LayoutPreferences, provider: InputSourceProviding = TISInputSourceProvider()) {
        self.preferences = preferences
        self.provider = provider

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

    /// Drops the cached layout list/index. Called from the TIS change
    /// notifications; exposed for tests to simulate an input-source change.
    func invalidateCaches() {
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
        let infos = provider.selectableLayouts()
        allLayoutsCache = infos
        infoCache = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return infos
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
        provider.currentInputSourceID()
    }

    // MARK: - Switching
    func toggleLayout() {
        let current = currentInputSourceID()
        let target = (current == preferences.secondaryID) ? preferences.primaryID : preferences.secondaryID
        switchLayout(to: target)
    }

    /// Switches the current keyboard layout to the specified input source ID.
    func switchLayout(to id: String) {
        provider.selectInputSource(id: id)
    }

    // MARK: - Layout selection (pure)

    /// Chooses a primary layout: the active one if known, else U.S., else ABC,
    /// else the first available (or a hard default when the list is empty).
    static func selectPrimary(current: String, available: [InputSourceInfo]) -> String {
        if !current.isEmpty { return current }
        if let us = available.first(where: { $0.id == "com.apple.keylayout.US" }) { return us.id }
        if let abc = available.first(where: { $0.id == "com.apple.keylayout.ABC" }) { return abc.id }
        return available.first?.id ?? "com.apple.keylayout.US"
    }

    /// Chooses a secondary layout of the opposite language family to `primary`
    /// (en ⇄ uk), falling back to any other available layout.
    static func selectSecondary(primary: String, available: [InputSourceInfo]) -> String {
        let primaryLang = available.first(where: { $0.id == primary })?.languages.first ?? ""
        let desiredPrefix = primaryLang.hasPrefix("en") ? "uk" : "en"
        if let differentLang = available.first(where: {
            $0.languages.contains(where: { $0.hasPrefix(desiredPrefix) }) && $0.id != primary
        }) {
            return differentLang.id
        }
        return available.first(where: { $0.id != primary })?.id ?? primary
    }
}
