import Cocoa

/// Handles status item and menu bar interactions.
final class MenuBarController: NSObject {
    private let layoutManager: KeyboardLayoutManager
    private let statusItem: NSStatusItem

    var onSetAsPrimary: ((String) -> Void)?
    var onSetAsSecondary: ((String) -> Void)?
    var onQuit: (() -> Void)?
    var onToggleConversion: (() -> Void)?

    private var menu: NSMenu?
    private var isConversionOn = true

    init(layoutManager: KeyboardLayoutManager) {
        self.layoutManager = layoutManager

        // NSStatusItem (and the underlying window it uses) must be
        // created on the main thread. In tests or other contexts this
        // initializer might be invoked from a background queue, so make
        // sure the status item creation always happens on the main thread.
        self.statusItem = Self.createStatusItem()
        super.init()

        // Further UI setup must also run on the main thread.
        if Thread.isMainThread {
            setupStatusItem()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setupStatusItem()
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
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateIcon()
        rebuildMenu()
        updateStatusTitleAndColor()
    }

    private func updateIcon() {
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

    func rebuildMenu() {
        let menu = NSMenu()

        let toggleTitle = isConversionOn ? "Conversion ON" : "Conversion OFF"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleConversionMenu), keyEquivalent: "0")
        toggleItem.keyEquivalentModifierMask = [.control, .option, .command]
        toggleItem.target = self
        menu.addItem(toggleItem)

        let quitItem = NSMenuItem(title: "Quit LayoutBuddy", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
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

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            onToggleConversion?()
        } else if event.type == .leftMouseUp {
            if let menu = menu {
                statusItem.popUpMenu(menu)
            }
        }
    }

    func setConversion(on: Bool) {
        isConversionOn = on
        updateIcon()
        rebuildMenu()
    }

    func updateStatusTitleAndColor() {
        let update = { [self] in
            guard let button = statusItem.button else { return }
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
