import Cocoa

/// Handles status item and menu bar interactions.
final class MenuBarController: NSObject {
    private let layoutManager: KeyboardLayoutManager
    private let preferences: LayoutPreferences
    private let statusItem: NSStatusItem?
    private let installsStatusItem: Bool

    var onSetAsPrimary: ((String) -> Void)?
    var onSetAsSecondary: ((String) -> Void)?
    var onQuit: (() -> Void)?
    var onToggleConversion: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onForceCorrectLastWord: (() -> Void)?
    var onCorrectLastAmbiguousWord: (() -> Void)?

    private var menu: NSMenu?
    private var isConversionOn = true

    init(layoutManager: KeyboardLayoutManager, preferences: LayoutPreferences) {
        self.layoutManager = layoutManager
        self.preferences = preferences
        let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.installsStatusItem = !runningTests
        if runningTests {
            self.statusItem = nil
        } else {
            // NSStatusItem (and the underlying window it uses) must be
            // created on the main thread. In tests or other contexts this
            // initializer might be invoked from a background queue, so make
            // sure the status item creation always happens on the main thread.
            self.statusItem = Self.createStatusItem()
        }
        super.init()

        guard installsStatusItem else { return }

        // Further UI setup must also run on the main thread.
        let performSetup = { [weak self] in self?.setupStatusItem() }
        if Thread.isMainThread {
            performSetup()
        } else {
            DispatchQueue.main.async {
                performSetup()
            }
        }
    }

    private static func createStatusItem() -> NSStatusItem {
        if Thread.isMainThread {
            return NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        } else {
            return DispatchQueue.main.sync {
                NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
        }
    }

    private func setupStatusItem() {
        guard let statusItem = statusItem else { return }

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateIcon()
        rebuildMenu()
        updateStatusTitleAndColor()

        // Reflect changes to hotkey preferences dynamically.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    private func updateIcon() {
        guard installsStatusItem else { return }
        let work = { [self] in
            guard let statusItem = statusItem else { return }
            let symbol = isConversionOn ? "infinity" : "infinity.circle.fill"
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "LayoutBuddy") {
                img.isTemplate = true // adopt menu bar tint (auto light/dark)
                statusItem.button?.image = img
                statusItem.button?.imagePosition = .imageOnly
            } else {
                // Fallback if SF Symbol unavailable (very old macOS): still icon-only
                statusItem.button?.title = "∞"
                statusItem.button?.imagePosition = .noImage
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    func rebuildMenu() {
        let build = { [self] in
            let menu = NSMenu()

            // Toggle conversion item with native key equivalent hint on the right
            let toggleBase = isConversionOn ? "Turn conversion OFF" : "Turn conversion ON"
            let toggleItem = NSMenuItem(title: toggleBase, action: #selector(toggleConversionMenu), keyEquivalent: "")
            toggleItem.target = self
            applyKeyEquivalent(toggleItem, from: preferences.toggleHotkey)
            menu.addItem(toggleItem)

            // Convert last ambiguous word with native key equivalent hint on the right
            let convertItem = NSMenuItem(title: "Convert last ambiguous word", action: #selector(convertLastAmbiguousWord), keyEquivalent: "")
            convertItem.target = self
            applyKeyEquivalent(convertItem, from: preferences.convertHotkey)
            menu.addItem(convertItem)

            // Force-correct last word with native key equivalent hint on the right
            let forceItem = NSMenuItem(title: "Force-correct last word", action: #selector(forceCorrectLastWord), keyEquivalent: "")
            forceItem.target = self
            applyKeyEquivalent(forceItem, from: preferences.forceCorrectHotkey)
            menu.addItem(forceItem)

            let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
            settingsItem.keyEquivalentModifierMask = [.command]
            settingsItem.target = self
            menu.addItem(settingsItem)

            let quitItem = NSMenuItem(title: "Quit LayoutBuddy", action: #selector(quit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            self.menu = menu
        }

        if Thread.isMainThread {
            build()
        } else {
            DispatchQueue.main.sync(execute: build)
        }
    }

    /// Apply an NSMenuItem key equivalent based on a Hotkey, to show a native
    /// right-aligned, dimmed shortcut hint without hardcoding.
    private func applyKeyEquivalent(_ item: NSMenuItem, from hotkey: Hotkey) {
        item.keyEquivalentModifierMask = hotkey.modifiers
        // Derive the base key from the display string (e.g., "⌃⌥⌘F" or "⌃⌥Space").
        let mods: Set<Character> = ["⌃", "⌥", "⌘", "⇧"]
        let remainder = hotkey.display.filter { !mods.contains($0) }
        if remainder == "Space" {
            item.keyEquivalent = " "
        } else if remainder.count == 1, let ch = remainder.first {
            item.keyEquivalent = String(ch).lowercased()
        } else {
            // Unknown or multi-char token (e.g., unsupported capture) → no key eq.
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    @objc private func setAsPrimary(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            onSetAsPrimary?(id)
        }
    }

    @objc private func setAsSecondary(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            onSetAsSecondary?(id)
        }
    }

    @objc private func quit() {
        onQuit?()
    }

    @objc private func toggleConversionMenu() {
        onToggleConversion?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func forceCorrectLastWord() {
        onForceCorrectLastWord?()
    }

    @objc private func convertLastAmbiguousWord() {
        onCorrectLastAmbiguousWord?()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard installsStatusItem, let statusItem = statusItem else { return }
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            onToggleConversion?()
        } else if let menu = menu, let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
    }

    func setConversion(on: Bool) {
        isConversionOn = on
        updateIcon()
        if installsStatusItem {
            rebuildMenu()
        }
    }

    func updateStatusTitleAndColor() {
        guard installsStatusItem else { return }
        let update = { [self] in
            guard let button = statusItem?.button else { return }
            // No text label in the menubar:
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            // Keep a tooltip with the current layout's full name:
            let curID = layoutManager.currentInputSourceID()
            button.toolTip = fullName(for: curID) // e.g., "U.S." or "Ukrainian - PC"
            // (Optional) If you ever want tint by layout, set:
            // button.contentTintColor = layoutManager.isLanguage(id: curID, hasPrefix: "uk") ? .systemBlue : .labelColor
        }

        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func shortName(for id: String) -> String {
        if layoutManager.isLanguage(id: id, hasPrefix: "uk") { return "UKR" }
        if layoutManager.isLanguage(id: id, hasPrefix: "en") { return "EN" }
        let name = layoutManager.inputSourceInfo(for: id)?.name ?? "???"
        return String(name.prefix(3)).uppercased()
    }

    private func fullName(for id: String) -> String {
        layoutManager.inputSourceInfo(for: id)?.name ?? id
    }
}
