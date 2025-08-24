import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: RefactorCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = RefactorCoordinator(
            input: EventTapInputMonitor(),
            capture: AXTextCapture(),
            resolver: LayoutMapper(),
            replace: AXReplacementPerformer(),
            ui: PopoverAmbiguityPresenter(),
            perms: AXPermissions()
        )
        coordinator?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
