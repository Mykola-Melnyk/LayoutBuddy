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
        return KeyboardLayoutManager.selectPrimary(current: current,
                                                   available: manager.listSelectableKeyboardLayouts())
    }

    func autoDetectSecondaryID() -> String {
        let manager = KeyboardLayoutManager(preferences: self)
        return KeyboardLayoutManager.selectSecondary(primary: primaryID,
                                                     available: manager.listSelectableKeyboardLayouts())
    }

    // MARK: - Hotkeys
    private let kToggleHotkeyKey = "ToggleConversionHotkey"
    private let kConvertHotkeyKey = "ConvertLastHotkey"
    private let kForceCorrectHotkeyKey = "ForceCorrectLastWordHotkey"
    private let kUndoCorrectionHotkeyKey = "UndoLastCorrectionHotkey"

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

    var undoCorrectionHotkey: Hotkey {
        get {
            if let data = defaults.data(forKey: kUndoCorrectionHotkeyKey),
               let hk = try? JSONDecoder().decode(Hotkey.self, from: data) {
                return hk
            }
            return Hotkey(
                keyCode: CGKeyCode(kVK_ANSI_Z),
                modifiers: [.control, .option, .command],
                display: "⌃⌥⌘Z"
            )
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: kUndoCorrectionHotkeyKey)
            }
        }
    }
}
