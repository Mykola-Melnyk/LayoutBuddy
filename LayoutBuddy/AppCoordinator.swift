import Cocoa
import ApplicationServices

/// Wires together the event tap, key handler and menu bar.
final class AppCoordinator: NSObject {
    private let preferences: LayoutPreferences
    private let layoutManager: KeyboardLayoutManager
    private let menuBar: MenuBarController
    private let eventTapController = EventTapController()

    private let mapper = KeyboardLayoutMapper()
    private let spellChecker = SpellCheckerService()
    private lazy var autoFixer = AutoFixer(mapper: mapper, spellChecker: spellChecker)
    private lazy var keyHandler = KeyHandler(layoutManager: layoutManager, autoFixer: autoFixer)

    init(preferences: LayoutPreferences = LayoutPreferences()) {
        self.preferences = preferences
        self.layoutManager = KeyboardLayoutManager(preferences: preferences)
        self.menuBar = MenuBarController(layoutManager: layoutManager)
        super.init()

        eventTapController.keyHandler = keyHandler

        menuBar.onSetAsPrimary = { [weak self] id in
            guard let self else { return }
            self.preferences.primaryID = id
            if self.preferences.secondaryID == self.preferences.primaryID {
                self.preferences.secondaryID = self.preferences.autoDetectSecondaryID()
            }
            self.playSwitchSound()
            self.menuBar.rebuildMenu()
            self.menuBar.updateStatusTitleAndColor()
        }

        menuBar.onSetAsSecondary = { [weak self] id in
            guard let self else { return }
            self.preferences.secondaryID = id
            self.playSwitchSound()
            self.menuBar.rebuildMenu()
            self.menuBar.updateStatusTitleAndColor()
        }

        menuBar.onQuit = {
            NSApplication.shared.terminate(nil)
        }
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        menuBar.updateStatusTitleAndColor()
        eventTapController.start()
    }

    func stop() {
        eventTapController.stop()
    }

    @objc private func toggleLayout() {
        layoutManager.toggleLayout()
        playSwitchSound()
        menuBar.updateStatusTitleAndColor()
    }

    private func playSwitchSound() { NSSound.beep() }

    // MARK: - Testing helpers

    func convert(_ word: String, from src: String, to dst: String) -> String {
        mapper.convert(word, from: src, to: dst)
    }

    @discardableResult
    func testHandleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        event.type = type
        return keyHandler.handle(event: event)
    }

    var testWordBuffer: String {
        get { keyHandler.wordParser.test_getBuffer() }
        set { keyHandler.wordParser.test_setBuffer(newValue) }
    }

    func test_setWordBuffer(_ text: String) { keyHandler.wordParser.test_setBuffer(text) }
    func test_getWordBuffer() -> String { keyHandler.wordParser.test_getBuffer() }
    func testSetSynthesizing(_ synth: Bool) { keyHandler.isSynthesizing = synth }
    func testQueuedEventsCount() -> Int { keyHandler.testQueuedEventsCount() }
}

