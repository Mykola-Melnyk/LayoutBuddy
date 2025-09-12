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

    // MARK: - Auto-detection
    func autoDetectPrimaryID() -> String {
        let manager = KeyboardLayoutManager(preferences: self)
        let current = manager.currentInputSourceID()
        if !current.isEmpty { return current }
        let all = manager.listSelectableKeyboardLayouts()
        if let us = all.first(where: { $0.id == "com.apple.keylayout.US" }) { return us.id }
        if let abc = all.first(where: { $0.id == "com.apple.keylayout.ABC" }) { return abc.id }
        return all.first?.id ?? "com.apple.keylayout.US"
    }

    func autoDetectSecondaryID() -> String {
        let manager = KeyboardLayoutManager(preferences: self)
        let primary = primaryID
        let all = manager.listSelectableKeyboardLayouts()
        let primaryLang = all.first(where: { $0.id == primary })?.languages.first ?? ""
        let desiredPrefix = primaryLang.hasPrefix("en") ? "uk" : "en"
        if let differentLang = all.first(where: {
            $0.languages.contains(where: { $0.hasPrefix(desiredPrefix) }) && $0.id != primary
        }) {
            return differentLang.id
        }
        return all.first(where: { $0.id != primary })?.id ?? primary
    }

    // MARK: - Hotkeys
    private let kToggleHotkeyKey = "ToggleConversionHotkey"
    private let kConvertHotkeyKey = "ConvertLastHotkey"
    private let kForceCorrectHotkeyKey = "ForceCorrectLastWordHotkey"

    var toggleHotkey: Hotkey {
        get {
            if let data = defaults.data(forKey: kToggleHotkeyKey),
               let hk = try? JSONDecoder().decode(Hotkey.self, from: data) {
                return hk
            }
            return Hotkey(
                keyCode: CGKeyCode(kVK_ANSI_0),
                modifiers: [.control, .option, .command],
                display: "⌃⌥⌘0"
            )
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: kToggleHotkeyKey)
            }
        }
    }

    var convertHotkey: Hotkey {
        get {
            if let data = defaults.data(forKey: kConvertHotkeyKey),
               let hk = try? JSONDecoder().decode(Hotkey.self, from: data) {
                return hk
            }
            return Hotkey(
                keyCode: CGKeyCode(kVK_Space),
                modifiers: [.control, .option],
                display: "⌃⌥Space"
            )
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: kConvertHotkeyKey)
            }
        }
    }

    var forceCorrectHotkey: Hotkey {
        get {
            if let data = defaults.data(forKey: kForceCorrectHotkeyKey),
               let hk = try? JSONDecoder().decode(Hotkey.self, from: data) {
                return hk
            }
            return Hotkey(
                keyCode: CGKeyCode(kVK_ANSI_F),
                modifiers: [.control, .option, .command],
                display: "⌃⌥⌘F"
            )
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: kForceCorrectHotkeyKey)
            }
        }
    }
}
