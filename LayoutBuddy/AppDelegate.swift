import Cocoa
import Carbon              // TIS* APIs + kVK_* keycodes
import ApplicationServices // Accessibility (AX) APIs


final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - State

    private var statusItem: NSStatusItem?
    
    // Toggle diagnostics here
    private let enableDiagnostics = false

    @inline(__always)
    private func dlog(_ msg: @autoclosure () -> String) {
        #if DEBUG
        if enableDiagnostics { Swift.print(msg()) }
        #endif
    }


    // Global key listener
    private var eventTap: CFMachPort?
    private var runLoopSrc: CFRunLoopSource?
    private var isSynthesizing = false

    // Word tracking
    private var wordBuffer = ""

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

    // MARK: - Preferences (primary / secondary layouts)

    private let kPrimaryIDKey = "PrimaryInputSourceID"
    private let kSecondaryIDKey = "SecondaryInputSourceID"

    private var primaryID: String {
        get { UserDefaults.standard.string(forKey: kPrimaryIDKey) ?? autoDetectPrimaryID() }
        set { UserDefaults.standard.set(newValue, forKey: kPrimaryIDKey) }
    }
    private var secondaryID: String {
        get { UserDefaults.standard.string(forKey: kSecondaryIDKey) ?? autoDetectSecondaryID() }
        set { UserDefaults.standard.set(newValue, forKey: kSecondaryIDKey) }
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let statusItem = statusItem else { return }
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
        setupEventTap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let src = runLoopSrc { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        eventTap = nil
        runLoopSrc = nil
    }

    // MARK: - Menubar UI

    private func rebuildMenu() {
        guard let statusItem = statusItem else { return }
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit LayoutBuddy", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func setAsPrimary(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            primaryID = id
            if secondaryID == primaryID { secondaryID = autoDetectSecondaryID() }
            playSwitchSound()
            rebuildMenu()
            updateStatusTitleAndColor()
        }
    }

    @objc private func setAsSecondary(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, id != primaryID {
            secondaryID = id
            playSwitchSound()
            rebuildMenu()
            updateStatusTitleAndColor()
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - Toggle

    @objc private func toggleLayout() {
        let current = currentInputSourceID()
        let target = (current == secondaryID) ? primaryID : secondaryID
        switchToInputSource(id: target)
        playSwitchSound()
        updateStatusTitleAndColor()
    }

    // MARK: - Badge

    private func updateStatusTitleAndColor() {
        guard let button = statusItem?.button else { return }
        // No text label in the menubar:
        button.title = ""                          // clear any plain title
        button.attributedTitle = NSAttributedString(string: "")
        // Keep a tooltip with the current layout's full name:
        let curID = currentInputSourceID()
        button.toolTip = fullName(for: curID)      // e.g., "U.S." or "Ukrainian - PC"
        // (Optional) If you ever want tint by layout, set:
        // button.contentTintColor = isLanguage(id: curID, hasPrefix: "uk") ? .systemBlue : .labelColor
    }


    private func shortName(for id: String) -> String {
        if isLanguage(id: id, hasPrefix: "uk") { return "UKR" }
        if isLanguage(id: id, hasPrefix: "en") { return "EN" }
        let name = inputSourceInfo(for: id)?.name ?? "???"
        return String(name.prefix(3)).uppercased()
    }

    private func fullName(for id: String) -> String {
        inputSourceInfo(for: id)?.name ?? id
    }

    private func isLanguage(id: String, hasPrefix prefix: String) -> Bool {
        inputSourceInfo(for: id)?.languages.contains(where: { $0.hasPrefix(prefix) }) ?? false
    }

    private func playSwitchSound() { NSSound.beep() }

    // MARK: - Input source helpers (Carbon/TIS)

    private struct InputSourceInfo {
        let id: String
        let name: String
        let languages: [String]
    }

    private func listSelectableKeyboardLayouts() -> [InputSourceInfo] {
        let query: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as CFString,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        guard let list = TISCreateInputSourceList(query as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }

        let infos = list.compactMap { src -> InputSourceInfo? in
            let id = (tisProperty(src, kTISPropertyInputSourceID) as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let name = (tisProperty(src, kTISPropertyLocalizedName) as? String) ?? id
            let langs = (tisProperty(src, kTISPropertyInputSourceLanguages) as? [String]) ?? []
            return InputSourceInfo(id: id, name: name, languages: langs)
        }
        return infos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func inputSourceInfo(for id: String) -> InputSourceInfo? {
        listSelectableKeyboardLayouts().first(where: { $0.id == id })
    }

    private func currentInputSourceID() -> String {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
        return (tisProperty(cur, kTISPropertyInputSourceID) as? String) ?? ""
    }

    private func switchToInputSource(id: String) {
        let query: [CFString: Any] = [
            kTISPropertyInputSourceID: id,
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as CFString,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        if let list = TISCreateInputSourceList(query as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource],
           let target = list.first {
            TISEnableInputSource(target)
            TISSelectInputSource(target)
        }
    }

    private func tisProperty(_ src: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }

    private func autoDetectPrimaryID() -> String {
        let current = currentInputSourceID()
        if !current.isEmpty { return current }
        let all = listSelectableKeyboardLayouts()
        if let us = all.first(where: { $0.id == "com.apple.keylayout.US" }) { return us.id }
        if let abc = all.first(where: { $0.id == "com.apple.keylayout.ABC" }) { return abc.id }
        return all.first?.id ?? "com.apple.keylayout.US"
    }

    private func autoDetectSecondaryID() -> String {
        let primary = primaryID
        let all = listSelectableKeyboardLayouts()
        let primaryLang = all.first(where: { $0.id == primary })?.languages.first ?? ""
        let desiredPrefix = primaryLang.hasPrefix("en") ? "uk" : "en"
        if let differentLang = all.first(where: {
            $0.languages.contains(where: { $0.hasPrefix(desiredPrefix) }) && $0.id != primary
        }) {
            return differentLang.id
        }
        return all.first(where: { $0.id != primary })?.id ?? primary
    }

    // MARK: - Event tap

    private func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: AppDelegate.eventCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else { return }
        eventTap = tap
        runLoopSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSrc, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
        return me.handleKeyEvent(type: type, event: event)
    }

    // MARK: - Word parsing helpers

    private let letterLikePunctScalars = Set("[];',.".unicodeScalars) // ABC keys → UA letters
    private func isMappedLatinPunctuation(_ s: UnicodeScalar) -> Bool {
        letterLikePunctScalars.contains(s)
    }

    private let trailingMappedScalars = Set(".,;".unicodeScalars)
    private func splitTrailingMapped(_ s: String) -> (core: String, trailingCount: Int) {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, trailingMappedScalars.contains(last) { scalars.removeLast() }
        let core = String(String.UnicodeScalarView(scalars))
        return (core, s.count - core.count)
    }

    private let suspicionMappedScalars = Set("[];,. ".unicodeScalars).subtracting(Set("'".unicodeScalars))
    private func containsSuspiciousMapped(_ s: String) -> Bool {
        s.unicodeScalars.contains { suspicionMappedScalars.contains($0) }
    }

    private let wordInternalScalars = Set("'’-".unicodeScalars) // keep inside words
    private func isWordInternal(_ s: UnicodeScalar) -> Bool { wordInternalScalars.contains(s) }

    private func isBoundary(_ s: UnicodeScalar) -> Bool {
        if isWordInternal(s) { return false }
        if CharacterSet.whitespacesAndNewlines.contains(s) { return true }
        let punct = ".,;:!?()[]{}<>/\\\"“”‘’—–_|@#€$%^&*+=`~"
        return punct.unicodeScalars.contains(s)
    }

    private func isLatinLetter(_ s: UnicodeScalar) -> Bool {
        ((0x41...0x5A).contains(s.value)) || ((0x61...0x7A).contains(s.value))
    }
    private func isCyrillicLetter(_ s: UnicodeScalar) -> Bool {
        (0x0400...0x04FF).contains(s.value) ||
        (0x0500...0x052F).contains(s.value) ||
        (0x2DE0...0x2DFF).contains(s.value) ||
        (0xA640...0xA69F).contains(s.value)
    }

    // MARK: - Key handling

    private func handleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if isSynthesizing { return Unmanaged.passUnretained(event) }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let flags   = event.flags
        let hasCmd  = flags.contains(.maskCommand)
        let hasCtrl = flags.contains(.maskControl)
        let hasAlt  = flags.contains(.maskAlternate)
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Hotkey: Control + Option + Space → apply most recent ambiguous word
        if hasCtrl && hasAlt && keyCode == CGKeyCode(kVK_Space) {
            dlog("[HOTKEY] pressed — stack=\(ambiguityStack.count)")
            if !ambiguityStack.isEmpty {
                DispatchQueue.main.async { self.applyMostRecentAmbiguityAndRestoreCaret() }
            } else {
                NSSound.beep()
            }
            return nil
        }

        // Ignore other Cmd/Ctrl shortcuts (let plain Alt combos pass)
        if hasCmd || hasCtrl { return Unmanaged.passUnretained(event) }

        // Backspace/delete edits the current word buffer without triggering processing
        if keyCode == CGKeyCode(kVK_Delete) || keyCode == CGKeyCode(kVK_ForwardDelete) {
            if hasAlt {
                wordBuffer = ""
            } else if !wordBuffer.isEmpty {
                wordBuffer.unicodeScalars.removeLast()
            }
            return Unmanaged.passUnretained(event)
        }

        // Decode typed scalar
        var buf = [UniChar](repeating: 0, count: 4)
        var len = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        guard len > 0, let scalar = UnicodeScalar(buf[0]) else {
            return Unmanaged.passUnretained(event)
        }

        // Letters & ABC-keys-that-map-to-UA-letters → extend current word
        let currentIsLatin = isLayoutLatin(currentInputSourceID())
        if isLatinLetter(scalar) || isCyrillicLetter(scalar) || (currentIsLatin && isMappedLatinPunctuation(scalar)) {
            wordBuffer.unicodeScalars.append(scalar)
            return Unmanaged.passUnretained(event)
        }

        // Boundary → evaluate buffered word, keep boundary char
        if isBoundary(scalar) {
            processBufferedWordIfNeeded(keepFollowingBoundary: true)
            bumpWordsAhead()
            return Unmanaged.passUnretained(event)
        }

        // Other symbols → treat like boundary
        processBufferedWordIfNeeded(keepFollowingBoundary: true)
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

    private func processBufferedWordIfNeeded(keepFollowingBoundary: Bool = false) {
        guard !wordBuffer.isEmpty else { return }

        let curID = currentInputSourceID()
        let curLangPrefix = isLayoutUkrainian(curID) ? "uk" : "en"
        let otherLangPrefix = (curLangPrefix == "en") ? "uk" : "en"

        let (core, _) = splitTrailingMapped(wordBuffer)
        let suspiciousEN = (curLangPrefix == "en") && containsSuspiciousMapped(core)

        guard let curSpell = bestSpellLang(for: curLangPrefix),
              let otherSpell = bestSpellLang(for: otherLangPrefix) else {
            wordBuffer = ""; return
        }

        // Single-letter policy
        if core.count == 1 {
            let curOK = isSpelledCorrect(core, language: curSpell)
            let converted1 = convert(core, from: curLangPrefix, to: otherLangPrefix)
            let otherOK = !converted1.isEmpty && isSpelledCorrect(converted1, language: otherSpell)

            if curOK && otherOK {
                captureAmbiguityLater(original: core, converted: converted1, targetLangPrefix: otherLangPrefix)
                wordBuffer = ""; return
            } else if !curOK && otherOK {
                replaceLastWord(with: converted1, targetLangPrefix: otherLangPrefix,
                                keepFollowingBoundary: keepFollowingBoundary, deleteCountOverride: core.count)
                playSwitchSound(); updateStatusTitleAndColor()
                wordBuffer = ""; return
            } else {
                wordBuffer = ""; return
            }
        }

        let curOK = !suspiciousEN && isSpelledCorrect(core, language: curSpell)
        let convertedCore = convert(core, from: curLangPrefix, to: otherLangPrefix)
        let otherOK = !convertedCore.isEmpty && isSpelledCorrect(convertedCore, language: otherSpell)

        // Tie: both valid → save candidate, no auto-change
        if curOK && otherOK {
            captureAmbiguityLater(original: core, converted: convertedCore, targetLangPrefix: otherLangPrefix)
            wordBuffer = ""; return
        }

        // Keep if current is valid
        if curOK && !otherOK { wordBuffer = ""; return }

        var shouldReplace = otherOK
        // Fallback: ABC-typed but looks Ukrainian after mapping
        if !shouldReplace, curLangPrefix == "en", containsSuspiciousMapped(core), isAllCyrillic(convertedCore) {
            shouldReplace = true
        }

        if shouldReplace {
            replaceLastWord(with: convertedCore, targetLangPrefix: otherLangPrefix,
                            keepFollowingBoundary: keepFollowingBoundary, deleteCountOverride: core.count)
            playSwitchSound(); updateStatusTitleAndColor()
        }

        wordBuffer = ""
    }

    private func isAllCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { isCyrillicLetter($0) }
    }

    // MARK: - Immediate auto-fix (simulate keys)

    private enum SpecialKey { case leftArrow, rightArrow }

    private func replaceLastWord(with newWord: String,
                                 targetLangPrefix: String,
                                 keepFollowingBoundary: Bool,
                                 deleteCountOverride: Int? = nil) {
        let deleteCount = deleteCountOverride ?? wordBuffer.count

        DispatchQueue.main.async {
            self.isSynthesizing = true
            if keepFollowingBoundary { self.tapKey(.leftArrow) } // keep trailing boundary (space, etc.)
            self.sendBackspace(times: deleteCount)

            let targetID = self.layoutID(forLanguagePrefix: targetLangPrefix) ?? self.otherLayoutID()
            self.ensureSwitch(to: targetID) {
                self.typeUnicode(newWord)
                if keepFollowingBoundary { self.tapKey(.rightArrow) }
                self.updateStatusTitleAndColor()
                self.isSynthesizing = false
            }
        }
    }

    private func sendBackspace(times: Int) {
        guard times > 0 else { return }
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vk = CGKeyCode(kVK_Delete)
        for _ in 0..<times {
            CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)?.post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func typeUnicode(_ text: String) {
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
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let code: CGKeyCode = (key == .leftArrow) ? CGKeyCode(kVK_LeftArrow) : CGKeyCode(kVK_RightArrow)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cgAnnotatedSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func tapKeyWithFlags(_ key: CGKeyCode, flags: CGEventFlags) {
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
            self.switchToInputSource(id: targetID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if self.currentInputSourceID() == targetID || n >= attempts { done() }
                else { attempt(n + 1) }
            }
        }
        attempt(1)
    }

    private func otherLayoutID() -> String {
        let cur = currentInputSourceID()
        return (cur == primaryID) ? secondaryID : primaryID
    }

    private func layoutID(forLanguagePrefix prefix: String) -> String? {
        if prefix == "uk" {
            if isLayoutUkrainian(primaryID) { return primaryID }
            if isLayoutUkrainian(secondaryID) { return secondaryID }
            return nil
        } else {
            if isLayoutLatin(primaryID) { return primaryID }
            if isLayoutLatin(secondaryID) { return secondaryID }
            return nil
        }
    }

    private func isLayoutUkrainian(_ id: String) -> Bool {
        if isLanguage(id: id, hasPrefix: "uk") { return true }
        let name = inputSourceInfo(for: id)?.name.lowercased() ?? ""
        return name.contains("ukrainian") || name.contains("україн")
    }

    private func isLayoutLatin(_ id: String) -> Bool {
        let langs = inputSourceInfo(for: id)?.languages ?? []
        if langs.contains(where: { $0.hasPrefix("en") }) { return true }
        if langs.contains(where: { $0.localizedCaseInsensitiveContains("latn") }) { return true }
        if langs.contains(where: { $0.hasPrefix("mul") }) { return true } // ABC often mul-Latn
        let name = inputSourceInfo(for: id)?.name.lowercased() ?? ""
        if name.contains("abc") || name.contains("u.s.") || name == "us" { return true }
        let idLower = id.lowercased()
        if idLower.contains("com.apple.keylayout.abc") || idLower.contains("com.apple.keylayout.us") { return true }
        return false
    }

    // MARK: - EN ⇄ UK keyboard-position mapping

    private func convert(_ word: String, from src: String, to dst: String) -> String {
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
    private func captureAmbiguityLater(original: String, converted: String, targetLangPrefix: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            self.captureAmbiguity(original: original, converted: converted, targetLangPrefix: targetLangPrefix)
        }
    }

    private func captureAmbiguity(original: String, converted: String, targetLangPrefix: String) {
        // Try AX path first
        if let el = axFocusedElement(),
           let caret = axSelectedRange(el),
           let full = axStringValue(el) {

            let ns = full as NSString
            let coreLen = (original as NSString).length
            let searchStart = max(0, caret.location - coreLen - 64)
            let window = NSRange(location: searchStart, length: max(0, caret.location - searchStart))
            let found = ns.range(of: original, options: [.backwards], range: window)
            guard found.location != NSNotFound else {
                // Could not locate string by AX → fall back to blind capture
                pushBlindAmbiguity(original: original, converted: converted, targetLangPrefix: targetLangPrefix)
                return
            }

            let beforeLen = min(contextRadius, found.location)
            let afterStart = found.location + found.length
            let afterLen = min(contextRadius, ns.length - afterStart)
            let before = ns.substring(with: NSRange(location: found.location - beforeLen, length: beforeLen))
            let after  = ns.substring(with: NSRange(location: afterStart, length: afterLen))

            let cand = AmbiguousCandidate(
                element: el,
                pid: axPID(el),
                range: CFRange(location: found.location, length: found.length),
                original: original, converted: converted,
                before: before, after: after,
                when: CFAbsoluteTimeGetCurrent(),
                targetLangPrefix: targetLangPrefix,
                keystrokeOnly: false, wordsAhead: 0
            )
            ambiguityStack.append(cand)
            if ambiguityStack.count > ambiguityMax { _ = ambiguityStack.removeFirst() }
            dlog("[TIE] saved: “\(original)” → “\(converted)” — stack=\(ambiguityStack.count)")
            return
        }

        // AX failed → blind candidate
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
                    playSwitchSound(); updateStatusTitleAndColor()
                }
                return
            }
        }

        // AX path failed → keystroke fallback
        fallbackNavigateAndReplace(cand)
    }

    private func fallbackTypeOverSelection(el: AXUIElement, text: String, restoreCaretTo pos: Int) {
        isSynthesizing = true
        typeUnicode(text)
        _ = axSetSelectedRange(el, NSRange(location: max(0, pos), length: 0))
        isSynthesizing = false
        playSwitchSound(); updateStatusTitleAndColor()
    }

    private func fallbackNavigateAndReplace(_ cand: AmbiguousCandidate) {
        DispatchQueue.main.async {
            self.isSynthesizing = true

            // Move back to the ambiguous word start
            let stepsLeft = max(1, cand.wordsAhead + 1)
            for _ in 0..<stepsLeft { self.optLeft() }

            // Select that word, delete selection
            self.shiftOptRight()
            self.sendBackspace(times: 1)

            // Switch to target layout and type converted word
            let targetID = self.layoutID(forLanguagePrefix: cand.targetLangPrefix) ?? self.otherLayoutID()
            self.ensureSwitch(to: targetID) {
                self.typeUnicode(cand.converted)
                // Return caret to where it was
                for _ in 0..<stepsLeft { self.optRight() }
                self.updateStatusTitleAndColor()
                self.playSwitchSound()
                self.isSynthesizing = false
            }
        }
    }
}
