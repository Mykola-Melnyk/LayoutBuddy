import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?            // ← add this
    private var coordinator: RefactorCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar icon
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = item
        if let button = item.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "keyboard",
                                       accessibilityDescription: "LayoutBuddy")
            } else {
                button.title = "LB"
            }
        }

        // (optional) prompt for Accessibility/Input Monitoring
        let perms = AXPermissions()
        perms.requestIfNeeded()

        // Start coordinator
        coordinator = RefactorCoordinator(
            input: EventTapInputMonitor(),
            capture: AXTextCapture(),
            resolver: LayoutMapper(),
            replace: AXReplacementPerformer(),
            ui: PopoverAmbiguityPresenter(), // ← or your presenter type
            perms: perms
        )
        coordinator?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
}
