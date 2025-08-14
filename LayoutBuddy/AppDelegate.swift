import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = LayoutPreferences()
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator(preferences: preferences)
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}

