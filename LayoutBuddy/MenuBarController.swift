import Cocoa

/// Handles status item and menu bar interactions.
final class MenuBarController: NSObject {
    private let layoutManager: KeyboardLayoutManager
    private let statusItem: NSStatusItem

    var onSetAsPrimary: ((String) -> Void)?
    var onSetAsSecondary: ((String) -> Void)?
    var onQuit: (() -> Void)?

    init(layoutManager: KeyboardLayoutManager) {
        self.layoutManager = layoutManager

        // Ensure status item is created on the main thread.
        var item: NSStatusItem!
        if Thread.isMainThread {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        } else {
            DispatchQueue.main.sync {
                item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
        }
        self.statusItem = item

        super.init()

        // Setup must also occur on the main thread.
        if Thread.isMainThread {
            setupStatusItem()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setupStatusItem()
            }
        }
    }

    private func setupStatusItem() {
        // Menu bar icon: ∞
        if let img = NSImage(systemSymbolName: "infinity", accessibilityDescription: "LayoutBuddy") {
            img.isTemplate = true // adopt menu bar tint (auto light/dark)
            statusItem.button?.image = img
            statusItem.button?.imagePosition = .imageOnly
        } else {
            // Fallback if SF Symbol unavailable (very old macOS): still icon-only
            statusItem.button?.title = "∞"
            statusItem.button?.imagePosition = .noImage
        }
        rebuildMenu()
        updateStatusTitleAndColor()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit LayoutBuddy", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
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

    func updateStatusTitleAndColor() {
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
