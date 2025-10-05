import Cocoa
import Carbon              // TIS* APIs + kVK_* keycodes
import ApplicationServices // Accessibility (AX) APIs
import SwiftUI


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
    private var conversionOn = true
    
    // Toggle diagnostics here
    private let enableDiagnostics = true

    @inline(__always)
    private func dlog(_ msg: @autoclosure () -> String) {
        #if DEBUG
        if enableDiagnostics { Swift.print(msg()) }
        #endif
    }


    // Global key listener
    private let eventTapController = EventTapController()
    private var isSynthesizing = false {
        didSet { if !isSynthesizing { flushQueuedEvents() } }
    }
    private var queuedEvents: [CGEvent] = []
    private let queuedEventsLock = NSLock()
    // When running unit tests, avoid posting real keyboard events to the session.
    private let isRunningUnitTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // Simulation support for unit tests
    private static var _testSimulationMode = false
    private var testSimulationMode: Bool { AppCoordinator._testSimulationMode }

    // Captured document text during tests
    var testDocumentText: String = ""

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

    // MARK: - App lifecycle

    init(preferences: LayoutPreferences = LayoutPreferences()) {
        self.preferences = preferences
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

        menuBar.onForceCorrectLastWord = { [weak self] in
            self?.forceCorrectLastWord()
        }

        menuBar.setConversion(on: conversionOn)
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        menuBar.updateStatusTitleAndColor()
        eventTapController.start()
    }

    func stop() {
        eventTapController.stop()
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
            let work = { [self] in
                if !ambiguityStack.isEmpty {
                    self.applyMostRecentAmbiguityAndRestoreCaret()
                } else {
                    NSSound.beep()
                }
            }
            if isRunningUnitTests || testSimulationMode {
                work()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
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

        // Ignore plain Option combos to avoid interfering with system shortcuts
        if hasAlt && !hasCmd && !hasCtrl { return Unmanaged.passUnretained(event) }

        if !conversionOn { return Unmanaged.passUnretained(event) }

        // Ignore other Cmd/Ctrl shortcuts
        if hasCmd || hasCtrl { return Unmanaged.passUnretained(event) }

        // Backspace/delete edits the current word buffer without triggering processing
        if keyCode == CGKeyCode(kVK_Delete) || keyCode == CGKeyCode(kVK_ForwardDelete) {
            if hasAlt {
                wordParser.clear()
            } else if !wordParser.buffer.isEmpty {
                wordParser.removeLast()
            }
            return Unmanaged.passUnretained(event)
        }

        guard let scalar = event.firstUnicodeScalar else {
            return Unmanaged.passUnretained(event)
        }

        dlog("[KEY] decoded scalar=\(scalar) buffer=\(wordParser.buffer)")

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

    // After each word boundary, everything on the stack moves one word “further back”
    private func bumpWordsAhead() {
        DispatchQueue.main.async {
            for i in self.ambiguityStack.indices {
                self.ambiguityStack[i].wordsAhead += 1
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

    // MARK: - Process a completed word

    private func processBufferedWordIfNeeded(keepFollowingBoundary: Bool = false, boundaryEvent: CGEvent? = nil) -> Bool {
        guard !wordParser.buffer.isEmpty else { return false }
        dlog("[PROC] entry buffer=\(wordParser.buffer)")

        let curID = layoutManager.currentInputSourceID()
        let curLangPrefix: String
        if (isRunningUnitTests || testSimulationMode) {
            if let first = wordParser.buffer.unicodeScalars.first,
               wordParser.isCyrillicLetter(first) {
                curLangPrefix = "uk"
            } else {
                curLangPrefix = "en"
            }
        } else {
            curLangPrefix = isLayoutUkrainian(curID) ? "uk" : "en"
        }
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
            let curOK = isSpelledCorrect(core, language: curSpell)
            let converted1 = convert(core, from: curLangPrefix, to: otherLangPrefix)
            dlog("[PROC] converted=\(converted1)")
            let otherOK = !converted1.isEmpty && isSpelledCorrect(converted1, language: otherSpell)

            if curOK && otherOK {
                captureAmbiguityLater(original: core, converted: converted1, targetLangPrefix: otherLangPrefix)
                dlog("[PROC] reset buffer")
                wordParser.clear(); return false
            } else if !curOK && otherOK {
                replaceLastWord(with: converted1, targetLangPrefix: otherLangPrefix,
                                keepFollowingBoundary: keepFollowingBoundary, boundaryEvent: boundaryEvent, deleteCountOverride: core.count)
                playSwitchSound(); menuBar.updateStatusTitleAndColor()
                dlog("[PROC] reset buffer")
                wordParser.clear(); return true
            } else {
                dlog("[PROC] reset buffer")
                wordParser.clear(); return false
            }
        }

        let curOK = !suspiciousEN && isSpelledCorrect(core, language: curSpell)
        let convertedCore = convert(core, from: curLangPrefix, to: otherLangPrefix)
        dlog("[PROC] converted=\(convertedCore)")
        let otherOK = !convertedCore.isEmpty && isSpelledCorrect(convertedCore, language: otherSpell)

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
            replaceLastWord(with: convertedCore, targetLangPrefix: otherLangPrefix,
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

    // MARK: - Force-correct last word action

    private func forceCorrectLastWord() {
        // Determine current and target language prefixes
        let curID = layoutManager.currentInputSourceID()
        let curLangPrefix: String = isLayoutUkrainian(curID) ? "uk" : "en"
        let targetLangPrefix: String = (curLangPrefix == "en") ? "uk" : "en"

        // If we are in the middle of typing a word, prefer using the in-memory buffer
        // to avoid relying on Accessibility APIs.
        if !wordParser.buffer.isEmpty {
            let core = wordParser.buffer
            let converted = convert(core, from: curLangPrefix, to: targetLangPrefix)
            // Use navigation-based replacement to avoid timing issues with backspaces.
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
            fallbackNavigateAndReplace(cand)
            return
        }

        #if DEBUG
        if isRunningUnitTests || testSimulationMode {
            if let r = lastWordRange(in: testDocumentText) {
                let word = String(testDocumentText[r])
                let converted = convert(word, from: curLangPrefix, to: targetLangPrefix)
                testDocumentText.replaceSubrange(r, with: converted)
            }
            playSwitchSound(); menuBar.updateStatusTitleAndColor()
            return
        }
        #endif

        // Fallback path without relying on Accessibility:
        // select the last word via Option navigation, copy it, convert, then replace selection.
        DispatchQueue.main.async {
            self.isSynthesizing = true
            self.optLeft()
            self.shiftOptRight()
            let pb = NSPasteboard.general
            pb.clearContents()
            self.tapKeyWithFlags(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let original = pb.string(forType: .string) ?? ""
                guard !original.isEmpty else { self.isSynthesizing = false; self.playSwitchSound(); return }
                let converted = self.convert(original, from: curLangPrefix, to: targetLangPrefix)
                // Replace the current selection
                self.sendBackspace(times: 1)
                let targetID = self.layoutID(forLanguagePrefix: targetLangPrefix) ?? self.otherLayoutID()
                self.ensureSwitch(to: targetID) {
                    self.typeUnicode(converted)
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

    private func replaceLastWord(with newWord: String,
                                 targetLangPrefix: String,
                                  keepFollowingBoundary: Bool,
                                 boundaryEvent: CGEvent? = nil,
                                 deleteCountOverride: Int? = nil) {
        let deleteCount = deleteCountOverride ?? wordParser.buffer.count
        #if DEBUG
        if isRunningUnitTests || testSimulationMode {
            let removeCount = min(deleteCount, testDocumentText.count)
            for _ in 0..<removeCount { testDocumentText.removeLast() }
            testDocumentText += newWord
            if let s = boundaryEvent?.firstUnicodeScalar {
                testDocumentText.unicodeScalars.append(s)
            }
            return
        }
        #endif

        DispatchQueue.main.async {
            let curID = self.layoutManager.currentInputSourceID()
            let targetID = self.layoutID(forLanguagePrefix: targetLangPrefix) ?? self.otherLayoutID()
            self.dlog("[REPLACE] start synth=\(self.isSynthesizing) curID=\(curID) targetID=\(targetID) buffer=\(self.wordParser.buffer)")
            self.isSynthesizing = true

            // Delay to let the system commit the most recent keystroke
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if keepFollowingBoundary { self.tapKey(.leftArrow) } // keep trailing boundary (space, etc.)
                self.sendBackspace(times: deleteCount)

                let targetID = self.layoutID(forLanguagePrefix: targetLangPrefix) ?? self.otherLayoutID()
                self.ensureSwitch(to: targetID) {
                    self.typeUnicode(newWord)
                    boundaryEvent?.post(tap: .cgAnnotatedSessionEventTap)
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
            CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)?.post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
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
            down?.post(tap: .cgAnnotatedSessionEventTap)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func tapKey(_ key: SpecialKey) {
        if isRunningUnitTests { return }
        #if DEBUG
        if testSimulationMode { return }
        #endif
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let code: CGKeyCode = (key == .leftArrow) ? CGKeyCode(kVK_LeftArrow) : CGKeyCode(kVK_RightArrow)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cgAnnotatedSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func tapKeyWithFlags(_ key: CGKeyCode, flags: CGEventFlags) {
        if isRunningUnitTests { return }
        #if DEBUG
        if testSimulationMode { return }
        #endif
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func optLeft()       { tapKeyWithFlags(CGKeyCode(kVK_LeftArrow),  flags: .maskAlternate) }
    private func optRight()      { tapKeyWithFlags(CGKeyCode(kVK_RightArrow), flags: .maskAlternate) }
    private func shiftOptRight() { tapKeyWithFlags(CGKeyCode(kVK_RightArrow), flags: [.maskAlternate, .maskShift]) }

    // Ensure layout really switched before typing
    private func ensureSwitch(to targetID: String, attempts: Int = 12, done: @escaping () -> Void) {
        func attempt(_ n: Int) {
            self.layoutManager.switchLayout(to: targetID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
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

    private func isLayoutUkrainian(_ id: String) -> Bool {
        if layoutManager.isLanguage(id: id, hasPrefix: "uk") { return true }
        let name = layoutManager.inputSourceInfo(for: id)?.name.lowercased() ?? ""
        return name.contains("ukrainian") || name.contains("україн")
    }

    private func isLayoutLatin(_ id: String) -> Bool {
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
        if src == "en", dst == "uk" { return mapWord(word, using: en2uk) }
        if src == "uk", dst == "en" { return mapWord(word, using: uk2en) }
        return word
    }

    private func mapWord(_ word: String, using table: [Character: String]) -> String {
        var out = ""
        for ch in word {
            let isUpper = ch.isUppercase
            let lower = Character(ch.lowercased())
            if let mapped = table[lower] {
                out += isUpper ? mapped.uppercased() : mapped
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private let en2uk: [Character: String] = [
        "q":"й","w":"ц","e":"у","r":"к","t":"е","y":"н","u":"г","i":"ш","o":"щ","p":"з","[":"х","]":"ї",
        "a":"ф","s":"і","d":"в","f":"а","g":"п","h":"р","j":"о","k":"л","l":"д",";":"ж","'":"є",
        "z":"я","x":"ч","c":"с","v":"м","b":"и","n":"т","m":"ь",",":"б",".":"ю","/":"."
    ]
    private lazy var uk2en: [Character: String] = {
        var rev: [Character: String] = [:]
        for (k,v) in en2uk { for ch in v { rev[ch] = String(k) } }
        rev["’"] = "'" // apostrophe variant
        return rev
    }()

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

    private func axStringValue(_ el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success,
           let s = ref as? String { return s }
        return nil
    }

    private func axSelectedRange(_ el: AXUIElement) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let val = ref,
              CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        let axVal = val as! AXValue
        var cfr = CFRange(location: 0, length: 0)
        if AXValueGetType(axVal) == .cfRange, AXValueGetValue(axVal, .cfRange, &cfr) {
            return NSRange(location: cfr.location, length: cfr.length)
        }
        return nil
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
        var cfr = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &cfr) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    private func axSetStringValue(_ el: AXUIElement, _ newValue: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success
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
                                       delay: Double = 0.05) {
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
           var full = axStringValue(el) {

            let ns = full as NSString
            guard let cr = cand.range else { fallbackNavigateAndReplace(cand); return }
            var finalRange = NSRange(location: cr.location, length: cr.length)

            if finalRange.location + finalRange.length > ns.length ||
               ns.substring(with: finalRange) != cand.original {
                // Re-locate by context near old index
                let windowStart = max(0, Int(cr.location) - 128)
                let windowEnd   = min(ns.length, Int(cr.location + cr.length) + 128)
                let window = NSRange(location: windowStart, length: max(0, windowEnd - windowStart))
                let needle = cand.before + cand.original + cand.after
                var found = ns.range(of: needle, options: [], range: window)
                if found.location != NSNotFound {
                    finalRange = NSRange(location: found.location + (cand.before as NSString).length,
                                         length: (cand.original as NSString).length)
                } else {
                    found = ns.range(of: cand.original, options: [.backwards], range: window)
                    if found.location == NSNotFound {
                        fallbackNavigateAndReplace(cand); return
                    }
                    finalRange = found
                }
            }

            // Replace via setValue on whole string (works in many fields)
            if axSetSelectedRange(el, finalRange) {
                full = axStringValue(el) ?? full
                let ns2 = full as NSString
                let newText = ns2.replacingCharacters(in: finalRange, with: cand.converted)

                isSynthesizing = true
                let ok = axSetStringValue(el, newText)
                // Restore caret:
                let originalLen = finalRange.length
                let convertedLen = (cand.converted as NSString).length
                let delta = convertedLen - originalLen
                let afterWordIndex = finalRange.location + finalRange.length

                let newCaret: Int
                if caretBefore.location >= afterWordIndex {
                    newCaret = caretBefore.location + delta
                } else if caretBefore.location >= finalRange.location && caretBefore.location <= afterWordIndex {
                    let insideOffset = caretBefore.location - finalRange.location
                    newCaret = finalRange.location + min(insideOffset, convertedLen)
                } else {
                    newCaret = caretBefore.location
                }
                _ = axSetSelectedRange(el, NSRange(location: max(0, newCaret), length: 0))
                isSynthesizing = false

                if !ok {
                    fallbackTypeOverSelection(el: el, text: cand.converted, restoreCaretTo: newCaret)
                } else {
            playSwitchSound(); menuBar.updateStatusTitleAndColor()
                }
                return
            }
        }

        // AX path failed → keystroke fallback
        fallbackNavigateAndReplace(cand)
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

    private func fallbackNavigateAndReplace(_ cand: AmbiguousCandidate) {
        #if DEBUG
        if isRunningUnitTests || testSimulationMode {
            _ = testSimulateAmbiguityOnTestText(cand)
            return
        }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let curID = self.layoutManager.currentInputSourceID()
            let targetID = self.layoutID(forLanguagePrefix: cand.targetLangPrefix) ?? self.otherLayoutID()
            self.dlog("[NAVREP] start synth=\(self.isSynthesizing) curID=\(curID) targetID=\(targetID) buffer=\(self.wordParser.buffer)")
            self.isSynthesizing = true

            // Move back to the ambiguous word start
            let stepsLeft = max(1, cand.wordsAhead + 1)
            for _ in 0..<stepsLeft { self.optLeft() }

            // Select that word, delete selection
            self.shiftOptRight()
            self.sendBackspace(times: 1)

            // Switch to target layout and type converted word
            self.dlog("[NAVREP] switching to targetID=\(targetID)")
            self.ensureSwitch(to: targetID) {
                self.dlog("[NAVREP] typing on targetID=\(targetID) synth=\(self.isSynthesizing)")
                self.typeUnicode(cand.converted)
                // Return caret to where it was
                for _ in 0..<stepsLeft { self.optRight() }
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
            _ = testSimulateAmbiguityOnTestText(cand)
            return
        }
        if testSimulationMode {
            _ = testSimulateAmbiguityOnTestText(cand)
            return
        }
        // Fallback to normal path
        fallbackNavigateAndReplace(cand)
    }

    func testCapturedText() -> String { testDocumentText }
}

// MARK: - EventTapControllerDelegate
extension AppCoordinator: EventTapControllerDelegate {
    func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        handleKeyEvent(event)
    }
}
