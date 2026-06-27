import Cocoa
import Carbon              // TIS* APIs + kVK_* keycodes
import ApplicationServices // Accessibility (AX) APIs
import SwiftUI
import os                  // os_log — diagnostics that survive Release builds


// MARK: - Helpers

private let lbLetters = CharacterSet.letters

private extension CGEvent {
    /// Returns the first unicode scalar from this keyboard event, if any.
    var firstUnicodeScalar: UnicodeScalar? {
        var length: Int = 0
        self.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return nil }
        var buffer = [UniChar](repeating: 0, count: length)
        self.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &buffer)
        if let u = buffer.first { return UnicodeScalar(u) }
        return nil
    }
}

@inline(__always)
private func isWordBoundaryOrPunctuation(_ s: UnicodeScalar) -> Bool {
    // treat any non-letter as a boundary (space, ., !, ?, enter, etc.)
    return !lbLetters.contains(s)
}


final class AppCoordinator: NSObject {

    // MARK: - State

    private let preferences: LayoutPreferences
    private let layoutManager: KeyboardLayoutManager
    private let menuBar: MenuBarController
    private let permissions = PermissionsManager()
    private var conversionOn = true
    
    // Diagnostics. Flip to true to trace via os_log in any build:
    //   log stream --predicate 'subsystem == "mmelnyk.LayoutBuddy"' --style compact
    private let enableDiagnostics = false
    private let diagLogger = Logger(subsystem: "mmelnyk.LayoutBuddy", category: "diag")

    @inline(__always)
    private func dlog(_ msg: @autoclosure () -> String) {
        guard enableDiagnostics else { return }
        let line = msg()
        diagLogger.log("\(line, privacy: .public)")
    }


    // Global key listener
    private let eventTapController = EventTapController()
    private let syntheticEventUserData: Int64 = 0x4C42_5359_4E54 // "LBSYNT"
    private var isSynthesizing = false {
        didSet { if !isSynthesizing { flushQueuedEvents() } }
    }
    private var queuedEvents: [CGEvent] = []
    private let queuedEventsLock = NSLock()
    // When running unit tests, avoid posting real keyboard events to the session.
    private let isRunningUnitTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private struct PasteboardSnapshot {
        private let items: [[NSPasteboard.PasteboardType: Data]]

        init(from pasteboard: NSPasteboard) {
            self.items = pasteboard.pasteboardItems?.map { item in
                var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        dataByType[type] = data
                    }
                }
                return dataByType
            } ?? []
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restoredItems = items.map { dataByType -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dataByType {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    // Simulation support for unit tests
    private static var _testSimulationMode = false
    private var testSimulationMode: Bool { AppCoordinator._testSimulationMode }

    // Captured document text during tests
    var testDocumentText: String = ""
    #if DEBUG
    private var testEditingInsideWordBeforeInput = false
    #endif

    // Word tracking
    private var wordParser = WordParser()
    private var inEmail = false

    // Spellchecker
    private let spellDocTag: Int = NSSpellChecker.uniqueSpellDocumentTag()

    // Ambiguity “fix later” stack
    private struct AmbiguousCandidate {
        let element: AXUIElement?          // nil when AX was unavailable
        let pid: pid_t                     // frontmost app pid when blind
        let range: CFRange?                // nil when blind
        let original: String
        let converted: String
        let before: String
        let after: String
        let when: CFAbsoluteTime
        let targetLangPrefix: String       // "en" or "uk"
        let keystrokeOnly: Bool            // true when saved blindly
        var wordsAhead: Int = 0            // words typed after this one
    }
    private var ambiguityStack: [AmbiguousCandidate] = []
    private let ambiguityMax = 5
    private let contextRadius = 8

    // Synthetic-keystroke choreography relies on giving the target app time to
    // commit edits and switch layouts. These are the (empirically tuned) delays;
    // centralised here so they are documented and tunable in one place rather
    // than sprinkled as bare literals through the async flow.
    private enum Timing {
        /// Let the system commit the most recent real keystroke before we edit.
        static let commitDelay = 0.05
        /// Poll interval while waiting for a layout switch to take effect.
        static let layoutSettle = 0.05
        /// Wait for ⌘C to populate the pasteboard before reading it.
        static let clipboardCopy = 0.12
        /// Delay before keystroke-navigation-based replacement.
        static let navReplace = 0.1
        /// Delay before the convert hotkey acts, so the boundary key lands first.
        static let convertHotkey = 0.1
        /// Re-check delay when saving a tie candidate after a boundary.
        static let captureTie = 0.05
    }

    private struct CorrectionUndo {
        let element: AXUIElement?
        let pid: pid_t
        let range: CFRange?
        let original: String
        let corrected: String
        let before: String
        let after: String
        let restoreLangPrefix: String
        let keystrokeOnly: Bool
        var wordsAhead: Int = 0
    }
    private var lastCorrectionUndo: CorrectionUndo?

    // MARK: - App lifecycle

    let userDictionary: UserDictionary

    init(preferences: LayoutPreferences = LayoutPreferences(),
         userDictionary: UserDictionary = UserDictionary()) {
        self.preferences = preferences
        self.userDictionary = userDictionary
        self.layoutManager = KeyboardLayoutManager(preferences: preferences)
        self.menuBar = MenuBarController(layoutManager: layoutManager, preferences: preferences)
        super.init()

        eventTapController.delegate = self

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

        menuBar.onToggleConversion = { [weak self] in
            self?.toggleConversion()
        }

        menuBar.onOpenSettings = { [weak self] in
            self?.openSettingsWindow()
        }

        menuBar.onOpenPermissions = { [weak self] in
            self?.presentOnboarding()
        }

        menuBar.onForceCorrectLastWord = { [weak self] in
            self?.forceCorrectLastWord()
        }

        menuBar.onCorrectLastAmbiguousWord = { [weak self] in
            self?.correctLastAmbiguousWord()
        }

        menuBar.onUndoLastCorrection = { [weak self] in
            self?.undoLastCorrection()
        }

        menuBar.setConversion(on: conversionOn)
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        menuBar.updateStatusTitleAndColor()
        if !eventTapController.start() {
            dlog("[EVENT TAP] failed to start; check Input Monitoring and Accessibility permissions")
        }
        // Walk the user through granting Accessibility + Input Monitoring on
        // first launch (or whenever a permission is missing).
        permissions.refresh()
        if !permissions.allGranted {
            presentOnboarding()
        }
    }

    func stop() {
        eventTapController.stop()
    }

    // MARK: - Onboarding / permissions

    private var onboardingWindow: NSWindow?

    private func presentOnboarding() {
        let show: () -> Void = { [self] in
            permissions.refresh()
            if let window = onboardingWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return
            }

            let view = OnboardingView(permissions: permissions) { [weak self] in
                self?.finishOnboarding()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "LayoutBuddy"
            window.styleMask = [.titled, .closable]
            window.center()
            window.isReleasedWhenClosed = false

            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.onboardingWindow = nil
            }

            onboardingWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        if Thread.isMainThread {
            show()
        } else {
            DispatchQueue.main.async(execute: show)
        }
    }

    private func finishOnboarding() {
        permissions.refresh()
        // Input Monitoring may now be granted — (re)try starting the event tap.
        _ = eventTapController.start()
        onboardingWindow?.close()
    }

    // MARK: - Settings

    private var settingsWindow: NSWindow?

    private func openSettingsWindow() {
        let show: () -> Void = { [self] in
            if let window = settingsWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return
            }

            eventTapController.stop()

            let controller = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.center()
            window.setFrameAutosaveName("Settings")
            window.isReleasedWhenClosed = false

            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.settingsWindow = nil
                self?.eventTapController.start()
            }

            settingsWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        if Thread.isMainThread {
            show()
        } else {
            DispatchQueue.main.async(execute: show)
        }
    }

    // MARK: - Toggle

    @objc private func toggleLayout() {
        layoutManager.toggleLayout()
        playSwitchSound()
        menuBar.updateStatusTitleAndColor()
    }

    private func toggleConversion() {
        conversionOn.toggle()
        wordParser.clear()
        menuBar.setConversion(on: conversionOn)
        playSwitchSound()
    }

    // MARK: - Feedback

    private func playSwitchSound() {
        let shouldPlay = UserDefaults.standard.object(forKey: "PlaySoundAtLayoutConversion") as? Bool ?? true
        guard shouldPlay else { return }
        let work = { NSSound.beep() }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func enqueueQueuedEvent(_ event: CGEvent) {
        queuedEventsLock.lock()
        queuedEvents.append(event)
        queuedEventsLock.unlock()
    }

    private func flushQueuedEvents() {
        queuedEventsLock.lock()
        let events = queuedEvents
        queuedEvents.removeAll()
        queuedEventsLock.unlock()

        // In tests, just drop queued events without posting to the system.
        if isRunningUnitTests { return }
        #if DEBUG
        if testSimulationMode { return }
        #endif

        for e in events {
            e.post(tap: .cgAnnotatedSessionEventTap)
            if let up = e.copy() {
                up.type = .keyUp
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    // MARK: - Key handling

    private func handleKeyEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if isSyntheticEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        if isSynthesizing {
            if let copy = event.copy() { enqueueQueuedEvent(copy) }
            return nil
        }
        guard event.type == .keyDown else { return Unmanaged.passUnretained(event) }

        let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let filtered: NSEvent.ModifierFlags = nsFlags.intersection([.command, .control, .option, .shift])
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let hasCmd  = filtered.contains(.command)
        let hasCtrl = filtered.contains(.control)
        let hasAlt  = filtered.contains(.option)

        let toggleHK = preferences.toggleHotkey
        if keyCode == toggleHK.keyCode && filtered == toggleHK.modifiers {
            if isRunningUnitTests || testSimulationMode {
                toggleConversion()
            } else {
                DispatchQueue.main.async { self.toggleConversion() }
            }
            return nil
        }

        let convertHK = preferences.convertHotkey
        if keyCode == convertHK.keyCode && filtered == convertHK.modifiers {
            dlog("[HOTKEY] pressed — stack=\(ambiguityStack.count)")
            let work = { [self] in self.correctLastAmbiguousWord() }
            if isRunningUnitTests || testSimulationMode {
                work()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.convertHotkey, execute: work)
            }
            return nil
        }

        // Force-correct last word hotkey
        let forceHK = preferences.forceCorrectHotkey
        if keyCode == forceHK.keyCode && filtered == forceHK.modifiers {
            let work = { [self] in self.forceCorrectLastWord() }
            if isRunningUnitTests || testSimulationMode { work() }
            else { DispatchQueue.main.async(execute: work) }
            return nil
        }

        let undoHK = preferences.undoCorrectionHotkey
        if keyCode == undoHK.keyCode && filtered == undoHK.modifiers {
            let work = { [self] in self.undoLastCorrection() }
            if isRunningUnitTests || testSimulationMode { work() }
            else { DispatchQueue.main.async(execute: work) }
            return nil
        }

        if isCaretNavigationKey(keyCode) {
            resetTypingStateAfterCaretMove()
            return Unmanaged.passUnretained(event)
        }

        // Ignore plain Option combos to avoid interfering with system shortcuts
        if hasAlt && !hasCmd && !hasCtrl { return Unmanaged.passUnretained(event) }

        if !conversionOn { return Unmanaged.passUnretained(event) }

        // Ignore other Cmd/Ctrl shortcuts
        if hasCmd || hasCtrl { return Unmanaged.passUnretained(event) }

        // Backspace/delete edits the current word buffer without triggering processing
        if keyCode == CGKeyCode(kVK_Delete) || keyCode == CGKeyCode(kVK_ForwardDelete) {
            if hasAlt || keyCode == CGKeyCode(kVK_ForwardDelete) || isEditingInsideWordBeforeInput() {
                resetTypingStateAfterCaretMove()
            } else if !wordParser.buffer.isEmpty {
                wordParser.removeLast()
            }
            return Unmanaged.passUnretained(event)
        }

        guard let scalar = event.firstUnicodeScalar else {
            return Unmanaged.passUnretained(event)
        }

        dlog("[KEY] decoded scalar=\(scalar) buffer=\(wordParser.buffer)")

        if !wordParser.buffer.isEmpty, isEditingInsideWordBeforeInput() {
            dlog("[KEY] editing-inside-word reset; dropped buffer=\(wordParser.buffer) scalar=\(scalar)")
            resetTypingStateAfterCaretMove()
            return Unmanaged.passUnretained(event)
        }

        if inEmail {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inEmail = false
                bumpWordsAhead()
            }
            return Unmanaged.passUnretained(event)
        }

        if scalar == UnicodeScalar(64) { // '@'
            wordParser.clear()
            inEmail = true
            bumpWordsAhead()
            return Unmanaged.passUnretained(event)
        }

        let currentIsLatin = isLayoutLatin(layoutManager.currentInputSourceID())
        if wordParser.isLatinLetter(scalar) || wordParser.isCyrillicLetter(scalar) || (currentIsLatin && wordParser.isMappedLatinPunctuation(scalar)) {
            dlog("[KEY] letters case buffer=\(wordParser.buffer) scalar=\(scalar)")
            if let first = wordParser.buffer.unicodeScalars.first {
                let firstIsLatin = wordParser.isLatinLetter(first) || wordParser.isMappedLatinPunctuation(first)
                let newIsLatin = wordParser.isLatinLetter(scalar) || (currentIsLatin && wordParser.isMappedLatinPunctuation(scalar))
                dlog("[KEY] script decision firstLatin=\(firstIsLatin) newLatin=\(newIsLatin) buffer=\(wordParser.buffer)")
                if firstIsLatin != newIsLatin {
                    dlog("[KEY] script mismatch before process buffer=\(wordParser.buffer) scalar=\(scalar)")
                    _ = processBufferedWordIfNeeded()
                    dlog("[KEY] script mismatch after process buffer=\(wordParser.buffer)")
                    bumpWordsAhead()
                }
            }
            dlog("[KEY] after script block buffer=\(wordParser.buffer)")
            wordParser.append(character: scalar)
            return Unmanaged.passUnretained(event)
        }

        if isWordBoundaryOrPunctuation(scalar) {
            let isReturn = keyCode == CGKeyCode(kVK_Return) || keyCode == CGKeyCode(kVK_ANSI_KeypadEnter)
            let isTab    = keyCode == CGKeyCode(kVK_Tab)
            let isEsc    = keyCode == CGKeyCode(kVK_Escape)
            let specialBoundary = isReturn || isTab || isEsc

            let eventCopy = specialBoundary ? nil : event.copy()
            dlog("[KEY] boundary before process buffer=\(wordParser.buffer) scalar=\(scalar)")
            let replaced = processBufferedWordIfNeeded(keepFollowingBoundary: specialBoundary, boundaryEvent: eventCopy)
            dlog("[KEY] boundary after process buffer=\(wordParser.buffer)")
            bumpWordsAhead()

            if specialBoundary {
                return Unmanaged.passUnretained(event)
            }

            if !replaced {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }

        wordParser.clear()
        bumpWordsAhead()
        return Unmanaged.passUnretained(event)
    }

    private func isCaretNavigationKey(_ keyCode: CGKeyCode) -> Bool {
        switch Int(keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return true
        default:
            return false
        }
    }

    private func resetTypingStateAfterCaretMove() {
        wordParser.clear()
        inEmail = false
        ambiguityStack.removeAll { $0.keystrokeOnly }
        if lastCorrectionUndo?.keystrokeOnly == true {
            lastCorrectionUndo = nil
        }
    }

    private func isEditingInsideWordBeforeInput() -> Bool {
        #if DEBUG
        if testSimulationMode { return testEditingInsideWordBeforeInput }
        #endif

        guard let el = axFocusedElement(),
              let caret = axSelectedRange(el) else {
            return false
        }

        if caret.length > 0 { return true }
        guard caret.location >= 0 else { return false }

        let nextRange = CFRange(location: caret.location, length: 1)
        guard let next = axStringForRange(el, nextRange) else { return false }
        return next.unicodeScalars.contains { lbLetters.contains($0) }
    }

    // After each word boundary, everything on the stack moves one word “further back”
    private func bumpWordsAhead() {
        DispatchQueue.main.async {
            for i in self.ambiguityStack.indices {
                self.ambiguityStack[i].wordsAhead += 1
            }
            if self.lastCorrectionUndo != nil {
                self.lastCorrectionUndo?.wordsAhead += 1
            }
        }
    }

    // MARK: - Spellcheck

    private func bestSpellLang(for prefix: String) -> String? {
        NSSpellChecker.shared.availableLanguages.first { $0.hasPrefix(prefix) }
    }

    private func isSpelledCorrect(_ word: String, language: String) -> Bool {
        let miss = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: spellDocTag, wordCount: nil
        )
        return miss.location == NSNotFound
    }

    /// Whether `word` counts as a valid word of `langPrefix` ("en"/"uk") — the
    /// user's custom dictionary first, then the system spell-checker.
    private func isValidWord(_ word: String, langPrefix: String, spellLanguage: String) -> Bool {
        userDictionary.contains(word, languagePrefix: langPrefix)
            || isSpelledCorrect(word, language: spellLanguage)
    }

    // MARK: - Process a completed word

    private func processBufferedWordIfNeeded(keepFollowingBoundary: Bool = false, boundaryEvent: CGEvent? = nil) -> Bool {
        guard !wordParser.buffer.isEmpty else { return false }
        dlog("[PROC] entry buffer=\(wordParser.buffer)")

        let curID = layoutManager.currentInputSourceID()
        // Decide the source language from what was actually TYPED (the buffer's
        // script), NOT the live keyboard layout. The layout can drift between
        // typing the word and hitting the boundary — and especially right after
        // an undo — so `currentInputSourceID()` may report ABC/English while the
        // buffer holds Cyrillic (or vice-versa), which misclassifies the word
        // and silently skips conversion. The buffer is ground truth.
        let firstLetter = wordParser.buffer.unicodeScalars.first {
            wordParser.isLatinLetter($0) || wordParser.isCyrillicLetter($0)
        }
        let curLangPrefix = (firstLetter.map { wordParser.isCyrillicLetter($0) } ?? false) ? "uk" : "en"
        let otherLangPrefix = (curLangPrefix == "en") ? "uk" : "en"

        let (core, _) = wordParser.splitTrailingMapped(wordParser.buffer)
        let suspiciousEN = (curLangPrefix == "en") && wordParser.containsSuspiciousMapped(core)

        guard let curSpell = bestSpellLang(for: curLangPrefix),
              let otherSpell = bestSpellLang(for: otherLangPrefix) else {
            dlog("[PROC] reset buffer")
            wordParser.clear(); return false
        }

        // Single-letter policy
        if core.count == 1 {
            let curOK = isValidWord(core, langPrefix: curLangPrefix, spellLanguage: curSpell)
            let converted1 = convert(core, from: curLangPrefix, to: otherLangPrefix)
            dlog("[PROC] converted=\(converted1)")
            // If nothing mapped, the "other language" form is identical — there
            // is no real alternative to consider.
            let otherOK = converted1 != core && !converted1.isEmpty && isValidWord(converted1, langPrefix: otherLangPrefix, spellLanguage: otherSpell)

            if curOK && otherOK {
                captureAmbiguityLater(original: core, converted: converted1, targetLangPrefix: otherLangPrefix)
                dlog("[PROC] reset buffer")
                wordParser.clear(); return false
            } else if !curOK && otherOK {
                replaceLastWord(original: core, with: converted1, restoreLangPrefix: curLangPrefix, targetLangPrefix: otherLangPrefix,
                                keepFollowingBoundary: keepFollowingBoundary, boundaryEvent: boundaryEvent, deleteCountOverride: core.count)
                playSwitchSound(); menuBar.updateStatusTitleAndColor()
                dlog("[PROC] reset buffer")
                wordParser.clear(); return true
            } else {
                dlog("[PROC] reset buffer")
                wordParser.clear(); return false
            }
        }

        let curOK = !suspiciousEN && isValidWord(core, langPrefix: curLangPrefix, spellLanguage: curSpell)
        let convertedCore = convert(core, from: curLangPrefix, to: otherLangPrefix)
        // If nothing mapped, the "other language" form is identical — skip it.
        let otherOK = convertedCore != core && !convertedCore.isEmpty && isValidWord(convertedCore, langPrefix: otherLangPrefix, spellLanguage: otherSpell)
        dlog("[PROC] decision curID=\(curID) curLang=\(curLangPrefix) core=\(core) converted=\(convertedCore) curOK=\(curOK) otherOK=\(otherOK)")

        // Tie: both valid → save candidate, no auto-change
        if curOK && otherOK {
            captureAmbiguityLater(original: core, converted: convertedCore, targetLangPrefix: otherLangPrefix)
            dlog("[PROC] reset buffer")
            wordParser.clear(); return false
        }

        // Keep if current is valid
        if curOK && !otherOK { dlog("[PROC] reset buffer"); wordParser.clear(); return false }

        var shouldReplace = otherOK
        // Fallback: ABC-typed but looks Ukrainian after mapping
        if !shouldReplace, curLangPrefix == "en", wordParser.containsSuspiciousMapped(core), isAllCyrillic(convertedCore) {
            shouldReplace = true
        }

        if shouldReplace {
            replaceLastWord(original: core, with: convertedCore, restoreLangPrefix: curLangPrefix, targetLangPrefix: otherLangPrefix,
                            keepFollowingBoundary: keepFollowingBoundary, boundaryEvent: boundaryEvent, deleteCountOverride: core.count)
            playSwitchSound(); menuBar.updateStatusTitleAndColor()
            dlog("[PROC] reset buffer")
            wordParser.clear()
            return true
        }
        dlog("[PROC] reset buffer")
        wordParser.clear()
        return false
    }

    private func isAllCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { wordParser.isCyrillicLetter($0) }
    }

    private func oppositeLanguagePrefix(_ prefix: String) -> String {
        prefix == "en" ? "uk" : "en"
    }

    private func rememberBlindUndo(original: String,
                                   corrected: String,
                                   restoreLangPrefix: String,
                                   wordsAhead: Int = 0) {
        guard !original.isEmpty, !corrected.isEmpty else { return }
        lastCorrectionUndo = CorrectionUndo(
            element: nil,
            pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            range: nil,
            original: original,
            corrected: corrected,
            before: "",
            after: "",
            restoreLangPrefix: restoreLangPrefix,
            keystrokeOnly: true,
            wordsAhead: wordsAhead
        )
    }

    private func rememberAXUndo(element: AXUIElement,
                                range: NSRange,
                                original: String,
                                corrected: String,
                                before: String,
                                after: String,
                                restoreLangPrefix: String) {
        guard !original.isEmpty, !corrected.isEmpty else { return }
        lastCorrectionUndo = CorrectionUndo(
            element: element,
            pid: axPID(element),
            range: CFRange(location: range.location, length: range.length),
            original: original,
            corrected: corrected,
            before: before,
            after: after,
            restoreLangPrefix: restoreLangPrefix,
            keystrokeOnly: false,
            wordsAhead: 0
        )
    }

    // MARK: - Ambiguity actions

    private func correctLastAmbiguousWord() {
        if ambiguityStack.isEmpty {
            if lastCorrectionUndo != nil {
                undoLastCorrection()
                return
            }
            NSSound.beep()
            return
        }
        applyMostRecentAmbiguityAndRestoreCaret()
    }

    private func undoLastCorrection() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.undoLastCorrection() }
            return
        }

        guard let undo = lastCorrectionUndo else {
            NSSound.beep()
            return
        }
        lastCorrectionUndo = nil

        #if DEBUG
        if isRunningUnitTests || testSimulationMode {
            if !testSimulateUndoOnTestText(undo) { NSSound.beep() }
            return
        }
        #endif

        // Prefer an exact-string AX replacement in the focused field (robust for
        // punctuation and blind undos); then the stored-range AX path; then keys.
        if axUndoByText(undo) { return }
        if !undo.keystrokeOnly, applyAXUndo(undo) { return }
        fallbackNavigateAndUndo(undo)
    }

    private func forceCorrectLastWord() {
        // Determine current and target language prefixes
        let curID = layoutManager.currentInputSourceID()
        let curLangPrefix: String = isLayoutUkrainian(curID) ? "uk" : "en"
        let targetLangPrefix: String = (curLangPrefix == "en") ? "uk" : "en"

        // If we are in the middle of typing a word, we know the exact text from
        // the in-memory buffer.
        if !wordParser.buffer.isEmpty {
            let core = wordParser.buffer
            let converted = convert(core, from: curLangPrefix, to: targetLangPrefix)
            let cand = AmbiguousCandidate(
                element: nil,
                pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                range: nil,
                original: core,
                converted: converted,
                before: "",
                after: "",
                when: CFAbsoluteTimeGetCurrent(),
                targetLangPrefix: targetLangPrefix,
                keystrokeOnly: true,
                wordsAhead: 0
            )
            wordParser.clear()

            #if DEBUG
            if isRunningUnitTests || testSimulationMode {
                fallbackNavigateAndReplace(cand)   // simulates on the test document
                return
            }
            #endif

            // Prefer a precise AX edit; fall back to keystroke navigation.
            if axReplaceWordBeforeCaret(original: core, with: converted,
                                        restoreLangPrefix: curLangPrefix,
                                        boundaryToInsert: nil) {
                let switchTo = layoutID(forLanguagePrefix: targetLangPrefix) ?? otherLayoutID()
                ensureSwitch(to: switchTo) { self.menuBar.updateStatusTitleAndColor() }
                playSwitchSound()
                return
            }
            fallbackNavigateAndReplace(cand)
            return
        }

        #if DEBUG
        if isRunningUnitTests || testSimulationMode {
            if let r = lastWordRange(in: testDocumentText) {
                let word = String(testDocumentText[r])
                let converted = convert(word, from: curLangPrefix, to: targetLangPrefix)
                let original = String(testDocumentText[r])
                testDocumentText.replaceSubrange(r, with: converted)
                rememberBlindUndo(original: original, corrected: converted, restoreLangPrefix: curLangPrefix)
            }
            playSwitchSound(); menuBar.updateStatusTitleAndColor()
            return
        }
        #endif

        // Prefer a precise Accessibility edit of the last word in the document.
        if axCorrectLastWordInDocument(curLangPrefix: curLangPrefix, targetLangPrefix: targetLangPrefix) {
            let switchTo = layoutID(forLanguagePrefix: targetLangPrefix) ?? otherLayoutID()
            ensureSwitch(to: switchTo) { self.menuBar.updateStatusTitleAndColor() }
            playSwitchSound()
            return
        }

        // Fallback path without relying on Accessibility:
        // select the last word via Option navigation, copy it, convert, then replace selection.
        DispatchQueue.main.async {
            self.isSynthesizing = true
            self.optLeft()
            self.shiftOptRight()
            let pb = NSPasteboard.general
            let clipboardSnapshot = PasteboardSnapshot(from: pb)
            pb.clearContents()
            self.tapKeyWithFlags(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.clipboardCopy) {
                let original = pb.string(forType: .string) ?? ""
                clipboardSnapshot.restore(to: pb)
                guard !original.isEmpty else { self.isSynthesizing = false; self.playSwitchSound(); return }
                let converted = self.convert(original, from: curLangPrefix, to: targetLangPrefix)
                // Replace the current selection
                self.sendBackspace(times: 1)
                let targetID = self.layoutID(forLanguagePrefix: targetLangPrefix) ?? self.otherLayoutID()
                self.ensureSwitch(to: targetID) {
                    self.typeUnicode(converted)
                    self.rememberBlindUndo(original: original, corrected: converted, restoreLangPrefix: curLangPrefix)
                    // Restore caret position after trailing boundary (e.g., space)
                    self.optRight()
                    self.menuBar.updateStatusTitleAndColor()
                    self.playSwitchSound()
                    self.isSynthesizing = false
                }
            }
        }
    }

    // MARK: - Immediate auto-fix (simulate keys)

    private enum SpecialKey { case leftArrow, rightArrow }

    private func replaceLastWord(original oldWord: String,
                                 with newWord: String,
                                 restoreLangPrefix: String,
                                 targetLangPrefix: String,
                                  keepFollowingBoundary: Bool,
                                 boundaryEvent: CGEvent? = nil,
                                 deleteCountOverride: Int? = nil) {
        let deleteCount = deleteCountOverride ?? wordParser.buffer.count
        let initialUndoWordsAhead = (keepFollowingBoundary || boundaryEvent != nil) ? -1 : 0
        #if DEBUG
        if isRunningUnitTests || testSimulationMode {
            let removeCount = min(deleteCount, testDocumentText.count)
            for _ in 0..<removeCount { testDocumentText.removeLast() }
            testDocumentText += newWord
            if let s = boundaryEvent?.firstUnicodeScalar {
                testDocumentText.unicodeScalars.append(s)
            }
            rememberBlindUndo(original: oldWord, corrected: newWord, restoreLangPrefix: restoreLangPrefix, wordsAhead: initialUndoWordsAhead)
            return
        }
        #endif

        DispatchQueue.main.async {
            self.dlog("[REPLACE] start synth=\(self.isSynthesizing) curID=\(self.layoutManager.currentInputSourceID()) buffer=\(self.wordParser.buffer)")

            // Prefer a precise Accessibility edit. A normal boundary (space,
            // punctuation) was swallowed from the event stream, so bake it back
            // in; a special boundary (return/tab) was let through and is handled
            // by the app itself, so there is nothing to reinsert.
            let boundaryToInsert: UnicodeScalar? = keepFollowingBoundary ? nil : boundaryEvent?.firstUnicodeScalar
            if self.axReplaceWordBeforeCaret(original: oldWord, with: newWord,
                                             restoreLangPrefix: restoreLangPrefix,
                                             boundaryToInsert: boundaryToInsert) {
                // The text edit needed no layout switch; switch only so the user
                // continues typing in the target layout (UX).
                let switchTo = self.layoutID(forLanguagePrefix: targetLangPrefix) ?? self.otherLayoutID()
                self.ensureSwitch(to: switchTo) { self.menuBar.updateStatusTitleAndColor() }
                return
            }

            // Fallback: synthetic-keystroke choreography for fields without AX.
            self.dlog("[REPLACE] AX unavailable; using keystroke fallback")
            self.isSynthesizing = true
            // Delay to let the system commit the most recent keystroke
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.commitDelay) {
                if keepFollowingBoundary { self.tapKey(.leftArrow) } // keep trailing boundary (space, etc.)
                self.sendBackspace(times: deleteCount)

                let switchTo = self.layoutID(forLanguagePrefix: targetLangPrefix) ?? self.otherLayoutID()
                self.ensureSwitch(to: switchTo) {
                    self.typeUnicode(newWord)
                    self.postSynthetic(boundaryEvent)
                    self.rememberBlindUndo(original: oldWord, corrected: newWord, restoreLangPrefix: restoreLangPrefix, wordsAhead: initialUndoWordsAhead)
                    if keepFollowingBoundary { self.tapKey(.rightArrow) }
                    self.menuBar.updateStatusTitleAndColor()
                    self.isSynthesizing = false
                }
            }
        }
    }

    private func sendBackspace(times: Int) {
        if isRunningUnitTests { return }
        #if DEBUG
        if testSimulationMode { return }
        #endif
        guard times > 0 else { return }
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vk = CGKeyCode(kVK_Delete)
        for _ in 0..<times {
            postSynthetic(CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true))
            postSynthetic(CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false))
        }
    }

    private func typeUnicode(_ text: String) {
        if isRunningUnitTests { return }
        #if DEBUG
        if testSimulationMode { return }
        #endif
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        for scalar in text.unicodeScalars {
            var u = UniChar(scalar.value)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            postSynthetic(down)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            postSynthetic(up)
        }
    }

    private func tapKey(_ key: SpecialKey) {
        if isRunningUnitTests { return }
        #if DEBUG
        if testSimulationMode { return }
        #endif
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let code: CGKeyCode = (key == .leftArrow) ? CGKeyCode(kVK_LeftArrow) : CGKeyCode(kVK_RightArrow)
        postSynthetic(CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true))
        postSynthetic(CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false))
    }

    private func tapKeyWithFlags(_ key: CGKeyCode, flags: CGEventFlags) {
        if isRunningUnitTests { return }
        #if DEBUG
        if testSimulationMode { return }
        #endif
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        down?.flags = flags
        postSynthetic(down)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        up?.flags = flags
        postSynthetic(up)
    }

    private func markSynthetic(_ event: CGEvent?) -> CGEvent? {
        event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
        return event
    }

    private func postSynthetic(_ event: CGEvent?) {
        markSynthetic(event)?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func isSyntheticEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventUserData
    }

    private func optLeft()       { tapKeyWithFlags(CGKeyCode(kVK_LeftArrow),  flags: .maskAlternate) }
    private func optRight()      { tapKeyWithFlags(CGKeyCode(kVK_RightArrow), flags: .maskAlternate) }
    private func shiftOptRight() { tapKeyWithFlags(CGKeyCode(kVK_RightArrow), flags: [.maskAlternate, .maskShift]) }
    private func shiftLeft()     { tapKeyWithFlags(CGKeyCode(kVK_LeftArrow),  flags: .maskShift) }

    // Ensure layout really switched before typing
    // Bumped on every ensureSwitch so a newer switch supersedes older retry
    // loops. Without this, an in-flight correction's "switch to Ukrainian" loop
    // keeps firing and overrides a subsequent undo's "switch to English",
    // leaving the wrong layout active — after which the next word converts as a
    // no-op and the app appears to "stop correcting".
    private var switchGeneration = 0

    private func ensureSwitch(to targetID: String, attempts: Int = 12, done: @escaping () -> Void) {
        switchGeneration += 1
        let generation = switchGeneration
        func attempt(_ n: Int) {
            guard generation == self.switchGeneration else { done(); return }  // superseded
            self.layoutManager.switchLayout(to: targetID)
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.layoutSettle) {
                guard generation == self.switchGeneration else { done(); return }
                if self.layoutManager.currentInputSourceID() == targetID || n >= attempts { done() }
                else { attempt(n + 1) }
            }
        }
        attempt(1)
    }

    private func otherLayoutID() -> String {
        let cur = layoutManager.currentInputSourceID()
        return (cur == preferences.primaryID) ? preferences.secondaryID : preferences.primaryID
    }

    private func layoutID(forLanguagePrefix prefix: String) -> String? {
        if prefix == "uk" {
            if isLayoutUkrainian(preferences.primaryID) { return preferences.primaryID }
            if isLayoutUkrainian(preferences.secondaryID) { return preferences.secondaryID }
            return nil
        } else {
            if isLayoutLatin(preferences.primaryID) { return preferences.primaryID }
            if isLayoutLatin(preferences.secondaryID) { return preferences.secondaryID }
            return nil
        }
    }

    // A given input-source id always maps to the same script, so memoize the
    // (otherwise string-heavy) classification. No invalidation needed: the
    // answer for an id never changes.
    private var ukrainianClassification: [String: Bool] = [:]
    private var latinClassification: [String: Bool] = [:]

    private func isLayoutUkrainian(_ id: String) -> Bool {
        if let cached = ukrainianClassification[id] { return cached }
        let result = computeIsLayoutUkrainian(id)
        ukrainianClassification[id] = result
        return result
    }

    private func computeIsLayoutUkrainian(_ id: String) -> Bool {
        if layoutManager.isLanguage(id: id, hasPrefix: "uk") { return true }
        let name = layoutManager.inputSourceInfo(for: id)?.name.lowercased() ?? ""
        return name.contains("ukrainian") || name.contains("україн")
    }

    private func isLayoutLatin(_ id: String) -> Bool {
        if let cached = latinClassification[id] { return cached }
        let result = computeIsLayoutLatin(id)
        latinClassification[id] = result
        return result
    }

    private func computeIsLayoutLatin(_ id: String) -> Bool {
        let langs = layoutManager.inputSourceInfo(for: id)?.languages ?? []
        if langs.contains(where: { $0.hasPrefix("en") }) { return true }
        if langs.contains(where: { $0.localizedCaseInsensitiveContains("latn") }) { return true }
        if langs.contains(where: { $0.hasPrefix("mul") }) { return true } // ABC often mul-Latn
        let name = layoutManager.inputSourceInfo(for: id)?.name.lowercased() ?? ""
        if name.contains("abc") || name.contains("u.s.") || name == "us" { return true }
        let idLower = id.lowercased()
        if idLower.contains("com.apple.keylayout.abc") || idLower.contains("com.apple.keylayout.us") { return true }
        return false
    }

    // MARK: - EN ⇄ UK keyboard-position mapping

    func convert(_ word: String, from src: String, to dst: String) -> String {
        KeyboardLayoutConverter.convert(word, from: src, to: dst)
    }

    // MARK: - Accessibility helpers & tie capture

    private func axFocusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()

        func copyAXElement(_ el: AXUIElement, _ attr: CFString) -> AXUIElement? {
            var ref: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, attr, &ref)
            guard err == .success, let val = ref, CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
            return (val as! AXUIElement)
        }

        if let direct = copyAXElement(sys, kAXFocusedUIElementAttribute as CFString) { return direct }

        if let appEl = copyAXElement(sys, kAXFocusedApplicationAttribute as CFString),
           let el = copyAXElement(appEl, kAXFocusedUIElementAttribute as CFString) { return el }

        if let app = NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            if let el = copyAXElement(appEl, kAXFocusedUIElementAttribute as CFString) { return el }
            if let winEl = copyAXElement(appEl, kAXFocusedWindowAttribute as CFString),
               let el = copyAXElement(winEl, kAXFocusedUIElementAttribute as CFString) { return el }
        }
        return nil
    }

    private func axPID(_ el: AXUIElement) -> pid_t {
        var pid: pid_t = 0; AXUIElementGetPid(el, &pid); return pid
    }

    // The raw AX value/selected-range marshalling lives in `AXTextTarget`; these
    // keep the existing element-based call sites (ambiguity/undo) working while
    // sharing a single implementation.
    private func axStringValue(_ el: AXUIElement) -> String? {
        AXTextTarget(element: el).text
    }

    private func axSelectedRange(_ el: AXUIElement) -> NSRange? {
        AXTextTarget(element: el).selection
    }

    private func axStringForRange(_ el: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var ref: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            el,
            kAXStringForRangeParameterizedAttribute as CFString,
            param,
            &ref
        ) == .success, let s = ref as? String {
            return s
        }
        return nil
    }

    private func focusedTextBeforeCaret() -> String {
        #if DEBUG
        if testSimulationMode { return testDocumentText }
        #endif
        if let el = axFocusedElement(), let caret = axSelectedRange(el) {
            let range = CFRange(location: 0, length: caret.location)
            return axStringForRange(el, range) ?? ""
        }
        return ""
    }

    private func axSetSelectedRange(_ el: AXUIElement, _ range: NSRange) -> Bool {
        AXTextTarget(element: el).select(range)
    }


    /// Re-locates a previously captured range inside the element's *current*
    /// text (it may have shifted as the user kept typing). Tries the stored
    /// range first, then a context-anchored search (`before+expected+after`),
    /// then a backwards search for the bare expected string. Returns nil if it
    /// can no longer be found.
    private func relocateRange(_ initial: NSRange,
                               in ns: NSString,
                               expecting expected: String,
                               before: String,
                               after: String) -> NSRange? {
        if initial.location + initial.length <= ns.length,
           ns.substring(with: initial) == expected {
            return initial
        }
        let windowStart = max(0, initial.location - 128)
        let windowEnd   = min(ns.length, initial.location + initial.length + 128)
        let window = NSRange(location: windowStart, length: max(0, windowEnd - windowStart))

        let needle = before + expected + after
        var found = ns.range(of: needle, options: [], range: window)
        if found.location != NSNotFound {
            return NSRange(location: found.location + (before as NSString).length,
                           length: (expected as NSString).length)
        }
        found = ns.range(of: expected, options: [.backwards], range: window)
        guard found.location != NSNotFound else { return nil }
        return found
    }

    /// Computes where the caret should land after `replacedRange` is swapped
    /// for text of length `newLength`.
    private func adjustedCaret(_ caret: Int,
                               afterReplacing replacedRange: NSRange,
                               withLength newLength: Int) -> Int {
        WordReplacementPlanner.adjustedCaret(caret, afterReplacing: replacedRange, withLength: newLength)
    }

    /// Surrounding text (±`contextRadius`) used to re-anchor a range during undo.
    private func axContext(around range: NSRange, in ns: NSString) -> (before: String, after: String) {
        WordReplacementPlanner.context(around: range, in: ns, radius: contextRadius)
    }

    /// Writes a computed `Plan` to a text target and records a precise undo when
    /// the target is backed by an AX element. Returns false (touching nothing
    /// observable) if the plan is nil or the write fails, so callers can fall
    /// back to synthetic keystrokes. Drives either a live element or a fake, so
    /// the whole read→plan→write→caret cycle is unit-testable.
    @discardableResult
    private func apply(_ plan: WordReplacementPlanner.Plan?,
                       on target: TextTarget,
                       restoreLangPrefix: String) -> Bool {
        guard let plan else { return false }
        isSynthesizing = true
        // Replace just the word's range (not the whole field) so the app doesn't
        // yank the caret to the start.
        let wrote = target.replace(plan.replacedRange, with: plan.replacement)
        // Some fields (web / Electron AX shims) accept the AX calls — selecting
        // the word — but never apply the text change, yet still report success.
        // Confirm the value actually changed before trusting it.
        let confirmed = wrote && target.text == plan.newText
        guard confirmed else {
            // The word may be left selected; collapse to a caret at the end of
            // the original word so the caller's keystroke fallback deletes the
            // right characters. Then report failure.
            _ = target.select(NSRange(location: plan.replacedRange.location + plan.replacedRange.length, length: 0))
            isSynthesizing = false
            return false
        }
        _ = target.select(NSRange(location: plan.newCaret, length: 0))
        isSynthesizing = false

        if let el = target.axElement {
            rememberAXUndo(element: el, range: plan.correctedRange,
                           original: plan.original, corrected: plan.converted,
                           before: plan.before, after: plan.after,
                           restoreLangPrefix: restoreLangPrefix)
        }
        return true
    }

    /// Replaces a *known* word sitting immediately before the caret in `target`
    /// — no synthetic keystrokes and no layout-switch timing. Returns false when
    /// the target is unreadable, has an active selection, or the word can't be
    /// confidently located, so the caller can fall back to synthetic keystrokes.
    ///
    /// - Parameter boundaryToInsert: a boundary (space/punctuation) that was
    ///   swallowed and must be reinserted after the corrected word. Pass nil
    ///   when the boundary is still in the document or when correcting mid-word.
    @discardableResult
    func replaceWord(on target: TextTarget,
                     original: String,
                     converted: String,
                     boundaryToInsert: UnicodeScalar?,
                     restoreLangPrefix: String) -> Bool {
        guard let text = target.text,
              let sel = target.selection, sel.length == 0 else { return false }
        let plan = WordReplacementPlanner.planReplacement(
            fullText: text as NSString, caret: sel.location,
            original: original, converted: converted,
            boundaryToInsert: boundaryToInsert, contextRadius: contextRadius)
        return apply(plan, on: target, restoreLangPrefix: restoreLangPrefix)
    }

    /// Finds the last word at or before the caret in `target` and converts it in
    /// place. Used by force-correct when there is no in-memory buffer. Returns
    /// false if the target is unreadable or no convertible word is found.
    @discardableResult
    func correctLastWord(on target: TextTarget,
                         convert: (String) -> String,
                         restoreLangPrefix: String) -> Bool {
        guard let text = target.text,
              let sel = target.selection, sel.length == 0 else { return false }
        let plan = WordReplacementPlanner.planLastWord(
            fullText: text as NSString, caret: sel.location,
            convert: convert, contextRadius: contextRadius)
        return apply(plan, on: target, restoreLangPrefix: restoreLangPrefix)
    }

    // AX entry points: resolve the focused element, then run the shared seam.
    @discardableResult
    private func axReplaceWordBeforeCaret(original: String,
                                          with converted: String,
                                          restoreLangPrefix: String,
                                          boundaryToInsert: UnicodeScalar?) -> Bool {
        guard let el = axFocusedElement() else { return false }
        return replaceWord(on: AXTextTarget(element: el),
                           original: original, converted: converted,
                           boundaryToInsert: boundaryToInsert,
                           restoreLangPrefix: restoreLangPrefix)
    }

    private func axCorrectLastWordInDocument(curLangPrefix: String, targetLangPrefix: String) -> Bool {
        guard let el = axFocusedElement() else { return false }
        return correctLastWord(on: AXTextTarget(element: el),
                               convert: { self.convert($0, from: curLangPrefix, to: targetLangPrefix) },
                               restoreLangPrefix: curLangPrefix)
    }

    // If AX fails at capture time, push a "blind" candidate so hotkey can still fix it.
    private func pushBlindAmbiguity(original: String, converted: String, targetLangPrefix: String) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let cand = AmbiguousCandidate(
            element: nil, pid: pid, range: nil,
            original: original, converted: converted,
            before: "", after: "",
            when: CFAbsoluteTimeGetCurrent(),
            targetLangPrefix: targetLangPrefix,
            keystrokeOnly: true, wordsAhead: 0
        )
        ambiguityStack.append(cand)
        if ambiguityStack.count > ambiguityMax { _ = ambiguityStack.removeFirst() }
        dlog("[TIE] (blind) saved: “\(original)” → “\(converted)” — stack=\(ambiguityStack.count)")
    }

    // Save tie slightly after boundary so target app updates selection
    private func captureAmbiguityLater(original: String,
                                       converted: String,
                                       targetLangPrefix: String,
                                       delay: Double = Timing.captureTie) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.isSynthesizing {
                self.captureAmbiguityLater(original: original,
                                           converted: converted,
                                           targetLangPrefix: targetLangPrefix,
                                           delay: delay)
            } else {
                self.captureAmbiguity(original: original,
                                      converted: converted,
                                      targetLangPrefix: targetLangPrefix)
            }
        }
    }

    private func captureAmbiguity(original: String, converted: String, targetLangPrefix: String) {
        if let el = axFocusedElement(), let caret = axSelectedRange(el) {
            let coreLen = (original as NSString).length
            if caret.location >= coreLen {
                let wordStart = caret.location - coreLen
                let wordRange = CFRange(location: wordStart, length: coreLen)
                if let word = axStringForRange(el, wordRange), word == original {
                    let beforeStart = max(0, wordStart - contextRadius)
                    let beforeRange = CFRange(location: beforeStart, length: wordStart - beforeStart)
                    let afterRange = CFRange(location: caret.location, length: contextRadius)
                    let before = axStringForRange(el, beforeRange) ?? ""
                    let after = axStringForRange(el, afterRange) ?? ""

                    let cand = AmbiguousCandidate(
                        element: el,
                        pid: axPID(el),
                        range: wordRange,
                        original: original,
                        converted: converted,
                        before: before,
                        after: after,
                        when: CFAbsoluteTimeGetCurrent(),
                        targetLangPrefix: targetLangPrefix,
                        keystrokeOnly: false,
                        wordsAhead: 0
                    )
                    ambiguityStack.append(cand)
                    if ambiguityStack.count > ambiguityMax { _ = ambiguityStack.removeFirst() }
                    dlog("[TIE] saved: “\(original)” → “\(converted)” — stack=\(ambiguityStack.count)")
                    return
                }

                // Fallback to older full-string search
                if let full = axStringValue(el) {
                    let ns = full as NSString
                    let searchStart = max(0, caret.location - coreLen - 64)
                    let window = NSRange(location: searchStart, length: max(0, caret.location - searchStart))
                    let found = ns.range(of: original, options: [.backwards], range: window)
                    if found.location != NSNotFound {
                        let beforeLen = min(contextRadius, found.location)
                        let afterStart = found.location + found.length
                        let afterLen = min(contextRadius, ns.length - afterStart)
                        let before = ns.substring(with: NSRange(location: found.location - beforeLen, length: beforeLen))
                        let after  = ns.substring(with: NSRange(location: afterStart, length: afterLen))

                        let cand = AmbiguousCandidate(
                            element: el,
                            pid: axPID(el),
                            range: CFRange(location: found.location, length: found.length),
                            original: original,
                            converted: converted,
                            before: before,
                            after: after,
                            when: CFAbsoluteTimeGetCurrent(),
                            targetLangPrefix: targetLangPrefix,
                            keystrokeOnly: false,
                            wordsAhead: 0
                        )
                        ambiguityStack.append(cand)
                        if ambiguityStack.count > ambiguityMax { _ = ambiguityStack.removeFirst() }
                        dlog("[TIE] saved: “\(original)” → “\(converted)” — stack=\(ambiguityStack.count)")
                        return
                    }
                }
            }
        }

        pushBlindAmbiguity(original: original, converted: converted, targetLangPrefix: targetLangPrefix)
    }

    // Apply most recent candidate; try AX (precise), else keystroke fallback
    private func applyMostRecentAmbiguityAndRestoreCaret() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.applyMostRecentAmbiguityAndRestoreCaret() }
            return
        }
        guard let cand = ambiguityStack.popLast() else { return }

        // If saved blindly, skip straight to keystroke fallback
        if cand.keystrokeOnly {
            fallbackNavigateAndReplace(cand)
            return
        }

        // Try AX path
        if let el = cand.element, axPID(el) == cand.pid,
           let caretBefore = axSelectedRange(el),
           let full = axStringValue(el) {

            let ns = full as NSString
            guard let cr = cand.range else { fallbackNavigateAndReplace(cand); return }
            let initialRange = NSRange(location: cr.location, length: cr.length)
            guard let finalRange = relocateRange(initialRange, in: ns, expecting: cand.original,
                                                 before: cand.before, after: cand.after) else {
                fallbackNavigateAndReplace(cand); return
            }

            // Replace just the selected word (setting the whole value would
            // yank the caret to the start of the field).
            if axSetSelectedRange(el, finalRange) {
                let convertedLen = (cand.converted as NSString).length
                let newCaret = adjustedCaret(caretBefore.location, afterReplacing: finalRange, withLength: convertedLen)
                isSynthesizing = true
                let wrote = AXTextTarget(element: el).replace(finalRange, with: cand.converted)
                // Confirm the field actually changed; some AX shims report
                // success but leave the word merely selected.
                let confirmed = wrote &&
                    axStringForRange(el, CFRange(location: finalRange.location, length: convertedLen)) == cand.converted
                if confirmed {
                    _ = axSetSelectedRange(el, NSRange(location: max(0, newCaret), length: 0))
                }
                isSynthesizing = false

                if confirmed {
                    let correctedRange = NSRange(location: finalRange.location, length: convertedLen)
                    rememberAXUndo(
                        element: el,
                        range: correctedRange,
                        original: cand.original,
                        corrected: cand.converted,
                        before: cand.before,
                        after: cand.after,
                        restoreLangPrefix: oppositeLanguagePrefix(cand.targetLangPrefix)
                    )
                    playSwitchSound(); menuBar.updateStatusTitleAndColor()
                } else {
                    // The word is still selected — type over it (works where AX
                    // text mutation doesn't).
                    fallbackTypeOverSelection(el: el, text: cand.converted, restoreCaretTo: newCaret)
                }
                return
            }
        }

        // AX path failed → keystroke fallback
        fallbackNavigateAndReplace(cand)
    }

    /// Undo by locating the exact corrected string in the *currently* focused
    /// element and replacing it with the original. Works for blind undos too
    /// (no stored element/range), and matches the corrected text exactly — so a
    /// punctuation-leading correction like ",fu" is removed whole, not split
    /// into ",баг". Cleanly collapses the selection afterwards.
    private func axUndoByText(_ undo: CorrectionUndo) -> Bool {
        guard let el = axFocusedElement(),
              let caret = axSelectedRange(el), caret.length == 0,
              let full = axStringValue(el) else { return false }
        // Stay in the field the correction happened in, when we know it.
        if undo.pid != 0, axPID(el) != undo.pid { return false }

        let ns = full as NSString
        let correctedLen = (undo.corrected as NSString).length
        guard correctedLen > 0, caret.location >= correctedLen, caret.location <= ns.length else { return false }

        // The (wordsAhead+1)-th last exact occurrence of the corrected text,
        // ending at or before the caret.
        var end = caret.location
        var range = NSRange(location: NSNotFound, length: 0)
        for _ in 0...max(0, undo.wordsAhead) {
            let found = ns.range(of: undo.corrected, options: .backwards, range: NSRange(location: 0, length: end))
            guard found.location != NSNotFound else { return false }
            range = found
            end = found.location
        }
        guard range.location != NSNotFound else { return false }

        let originalLen = (undo.original as NSString).length
        isSynthesizing = true
        let wrote = AXTextTarget(element: el).replace(range, with: undo.original)
        let confirmed = wrote &&
            axStringForRange(el, CFRange(location: range.location, length: originalLen)) == undo.original
        if confirmed {
            let newCaret = adjustedCaret(caret.location, afterReplacing: range, withLength: originalLen)
            _ = axSetSelectedRange(el, NSRange(location: max(0, newCaret), length: 0))
        } else {
            // Collapse any selection we created so it can't disrupt the next word.
            _ = axSetSelectedRange(el, NSRange(location: range.location + range.length, length: 0))
        }
        isSynthesizing = false

        guard confirmed else { return false }
        restoreLayoutAfterUndo(undo.restoreLangPrefix)
        return true
    }

    private func applyAXUndo(_ undo: CorrectionUndo) -> Bool {
        guard let el = undo.element, axPID(el) == undo.pid,
              let caretBefore = axSelectedRange(el),
              let full = axStringValue(el),
              let cr = undo.range else {
            return false
        }

        let ns = full as NSString
        let initialRange = NSRange(location: cr.location, length: cr.length)
        guard let finalRange = relocateRange(initialRange, in: ns, expecting: undo.corrected,
                                             before: undo.before, after: undo.after) else {
            return false
        }

        guard axSetSelectedRange(el, finalRange) else { return false }
        // Replace just the selected word rather than rewriting the whole value,
        // which would yank the caret to the start of the field.
        let originalLen = (undo.original as NSString).length
        isSynthesizing = true
        let wrote = AXTextTarget(element: el).replace(finalRange, with: undo.original)
        // Confirm it took; some AX shims report success without applying the edit.
        let confirmed = wrote &&
            axStringForRange(el, CFRange(location: finalRange.location, length: originalLen)) == undo.original
        if confirmed {
            let newCaret = adjustedCaret(caretBefore.location, afterReplacing: finalRange, withLength: originalLen)
            _ = axSetSelectedRange(el, NSRange(location: max(0, newCaret), length: 0))
        }
        isSynthesizing = false

        guard confirmed else { return false }   // → keystroke fallback (fallbackNavigateAndUndo)
        restoreLayoutAfterUndo(undo.restoreLangPrefix)
        return true
    }

    private func fallbackTypeOverSelection(el: AXUIElement, text: String, restoreCaretTo pos: Int) {
        dlog("[FALLBACK typeover] start synth=\(isSynthesizing) curID=\(layoutManager.currentInputSourceID()) buffer=\(wordParser.buffer)")
        isSynthesizing = true
        typeUnicode(text)
        _ = axSetSelectedRange(el, NSRange(location: max(0, pos), length: 0))
        isSynthesizing = false
        dlog("[FALLBACK typeover] end synth=\(isSynthesizing) curID=\(layoutManager.currentInputSourceID()) buffer=\(wordParser.buffer)")
        playSwitchSound(); menuBar.updateStatusTitleAndColor()
    }

    private func restoreLayoutAfterUndo(_ languagePrefix: String) {
        let finish = {
            self.menuBar.updateStatusTitleAndColor()
            self.playSwitchSound()
        }

        guard let targetID = layoutID(forLanguagePrefix: languagePrefix) else {
            finish()
            return
        }
        ensureSwitch(to: targetID, done: finish)
    }

    private func fallbackNavigateAndUndo(_ undo: CorrectionUndo) {
        let cand = AmbiguousCandidate(
            element: nil,
            pid: undo.pid,
            range: nil,
            original: undo.corrected,
            converted: undo.original,
            before: undo.before,
            after: undo.after,
            when: CFAbsoluteTimeGetCurrent(),
            targetLangPrefix: undo.restoreLangPrefix,
            keystrokeOnly: true,
            wordsAhead: undo.wordsAhead
        )
        fallbackNavigateAndReplace(cand, recordUndo: false)
    }

    private func fallbackNavigateAndReplace(_ cand: AmbiguousCandidate, recordUndo: Bool = true) {
        #if DEBUG
        if isRunningUnitTests || testSimulationMode {
            if testSimulateAmbiguityOnTestText(cand), recordUndo {
                rememberBlindUndo(
                    original: cand.original,
                    corrected: cand.converted,
                    restoreLangPrefix: oppositeLanguagePrefix(cand.targetLangPrefix),
                    wordsAhead: cand.wordsAhead
                )
            }
            return
        }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.navReplace) {
            let curID = self.layoutManager.currentInputSourceID()
            let targetID = self.layoutID(forLanguagePrefix: cand.targetLangPrefix) ?? self.otherLayoutID()
            self.dlog("[NAVREP] start synth=\(self.isSynthesizing) curID=\(curID) targetID=\(targetID) buffer=\(self.wordParser.buffer)")
            self.isSynthesizing = true

            // Undo of the most recent correction: the caret is right after the
            // corrected text, so select it by exact length. Word navigation
            // would split a leading-punctuation correction (",fu") and leave
            // the comma behind (",fuбаг"). Other cases still navigate by word.
            let exactSelect = !recordUndo && cand.wordsAhead == 0
            let stepsLeft = max(1, cand.wordsAhead + 1)

            if exactSelect {
                for _ in 0..<cand.original.count { self.shiftLeft() }
            } else {
                for _ in 0..<stepsLeft { self.optLeft() }
                self.shiftOptRight()
            }
            self.sendBackspace(times: 1)

            // Switch to target layout and type converted word
            self.dlog("[NAVREP] switching to targetID=\(targetID)")
            self.ensureSwitch(to: targetID) {
                self.dlog("[NAVREP] typing on targetID=\(targetID) synth=\(self.isSynthesizing)")
                self.typeUnicode(cand.converted)
                if recordUndo {
                    self.rememberBlindUndo(
                        original: cand.original,
                        corrected: cand.converted,
                        restoreLangPrefix: self.oppositeLanguagePrefix(cand.targetLangPrefix),
                        wordsAhead: cand.wordsAhead
                    )
                }
                // Return caret to where it was (word-nav case only)
                if !exactSelect {
                    for _ in 0..<stepsLeft { self.optRight() }
                }
                self.menuBar.updateStatusTitleAndColor()
                self.playSwitchSound()
                self.isSynthesizing = false
                self.dlog("[NAVREP] end synth=\(self.isSynthesizing) curID=\(self.layoutManager.currentInputSourceID()) buffer=\(self.wordParser.buffer)")
            }
        }
    }
    // MARK: - Testing helpers
    /// Expose the internal word buffer for unit tests.
    func test_setWordBuffer(_ text: String) { wordParser.test_setBuffer(text) }
    func test_getWordBuffer() -> String { wordParser.test_getBuffer() }

}

extension AppCoordinator {
    /// Exposes the internal word buffer for testing.
    var testWordBuffer: String {
        get { wordParser.test_getBuffer() }
        set { wordParser.test_setBuffer(newValue) }
    }

    /// Wrapper to access the private `handleKeyEvent` in tests.
    func testHandleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        handleKeyEvent(event)
    }

    /// Allows tests to toggle synthesizing state.
    func testSetSynthesizing(_ value: Bool) { isSynthesizing = value }

    func testMarkSynthetic(_ event: CGEvent) {
        _ = markSynthetic(event)
    }

    /// Returns the number of events queued while synthesizing.
    func testQueuedEventsCount() -> Int {
        queuedEventsLock.lock(); defer { queuedEventsLock.unlock() }
        return queuedEvents.count
    }

    // Enable deterministic simulation mode for unit tests (no CGEvents posted).
    func testSetSimulationMode(_ on: Bool) { AppCoordinator._testSimulationMode = on }

    /// Expose conversion toggle state for tests.
    var testConversionOn: Bool { conversionOn }

    // Unicode-aware helper returning the range of the last word in `text`.
    // Supports Unicode letters including Cyrillic.
    private func lastWordRange(in text: some StringProtocol) -> Range<String.Index>? {
        guard !text.isEmpty else { return nil }
        let letters = CharacterSet.letters

        var end = text.endIndex
        var start = end

        // walk left skipping non-letters
        while start > text.startIndex {
            let p = text.index(before: start)
            if text[p].unicodeScalars.allSatisfy({ letters.contains($0) }) {
                break
            }
            start = p
        }
        end = start

        // walk left across letters
        while start > text.startIndex {
            let p = text.index(before: start)
            if text[p].unicodeScalars.allSatisfy({ letters.contains($0) }) {
                start = p
            } else {
                break
            }
        }

        return start < end ? start..<end : nil
    }

    // Simulate applying the ambiguity to the test text using Unicode-aware word bounds.
    private func testSimulateAmbiguityOnTestText(_ cand: AmbiguousCandidate) -> Bool {
        var searchEnd = testDocumentText.endIndex
        var targetRange: Range<String.Index>? = nil
        for _ in 0...cand.wordsAhead {
            guard let r = lastWordRange(in: testDocumentText[..<searchEnd]) else { return false }
            targetRange = r
            searchEnd = r.lowerBound
        }
        guard let range = targetRange else { return false }
        testDocumentText.replaceSubrange(range, with: cand.converted)
        return true
    }

    private func testSimulateUndoOnTestText(_ undo: CorrectionUndo) -> Bool {
        // Locate the (wordsAhead+1)-th last word to respect how far back the
        // correction is, then anchor on that word's END and extend left by the
        // corrected length. The corrected form may start with punctuation —
        // e.g. "баг" → ",fu" — which a plain word match would split, leaving the
        // original merely inserted (",fuбаг").
        var searchEnd = testDocumentText.endIndex
        var wordRange: Range<String.Index>? = nil
        for _ in 0...max(0, undo.wordsAhead) {
            guard let r = lastWordRange(in: testDocumentText[..<searchEnd]) else { return false }
            wordRange = r
            searchEnd = r.lowerBound
        }
        guard let wr = wordRange,
              let start = testDocumentText.index(wr.upperBound, offsetBy: -undo.corrected.count,
                                                 limitedBy: testDocumentText.startIndex) else { return false }
        let range = start..<wr.upperBound
        guard String(testDocumentText[range]) == undo.corrected else { return false }
        testDocumentText.replaceSubrange(range, with: undo.original)
        return true
    }

    /// Seed an ambiguity candidate for tests.
    func testPushAmbiguity(original: String, converted: String, targetLangPrefix: String, wordsAhead: Int) {
        let cand = AmbiguousCandidate(
            element: nil, pid: 0, range: nil,
            original: original, converted: converted,
            before: "", after: "",
            when: CFAbsoluteTimeGetCurrent(),
            targetLangPrefix: targetLangPrefix,
            keystrokeOnly: true, wordsAhead: wordsAhead
        )
        ambiguityStack.append(cand)
    }

    /// Invoke hotkey application directly in tests.
    func testApplyMostRecentAmbiguityNow() {
        applyMostRecentAmbiguityAndRestoreCaret()
    }

    /// Apply the most recent ambiguity synchronously for deterministic tests.
    func testApplyMostRecentAmbiguitySynchronously() {
        guard !ambiguityStack.isEmpty else { return }
        let cand = ambiguityStack.removeLast()
        if isRunningUnitTests {
            if testSimulateAmbiguityOnTestText(cand) {
                rememberBlindUndo(
                    original: cand.original,
                    corrected: cand.converted,
                    restoreLangPrefix: oppositeLanguagePrefix(cand.targetLangPrefix),
                    wordsAhead: cand.wordsAhead
                )
            }
            return
        }
        if testSimulationMode {
            if testSimulateAmbiguityOnTestText(cand) {
                rememberBlindUndo(
                    original: cand.original,
                    corrected: cand.converted,
                    restoreLangPrefix: oppositeLanguagePrefix(cand.targetLangPrefix),
                    wordsAhead: cand.wordsAhead
                )
            }
            return
        }
        // Fallback to normal path
        fallbackNavigateAndReplace(cand)
    }

    func testUndoLastCorrectionSynchronously() {
        undoLastCorrection()
    }

    /// Seed a blind correction-undo for tests.
    func testRememberBlindUndo(original: String, corrected: String, restoreLangPrefix: String, wordsAhead: Int = 0) {
        rememberBlindUndo(original: original, corrected: corrected, restoreLangPrefix: restoreLangPrefix, wordsAhead: wordsAhead)
    }

    func testSetEditingInsideWordBeforeInput(_ editing: Bool) {
        #if DEBUG
        testEditingInsideWordBeforeInput = editing
        #endif
    }

    func testCapturedText() -> String { testDocumentText }
}

// MARK: - EventTapControllerDelegate
extension AppCoordinator: EventTapControllerDelegate {
    func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        handleKeyEvent(event)
    }
}
