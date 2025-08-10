import Cocoa
import Carbon   // TIS* APIs + kVK_* codes

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - State & Preferences

    private var statusItem: NSStatusItem!

    // Input monitoring (global key listener)
    private var eventTap: CFMachPort?
    private var runLoopSrc: CFRunLoopSource?
    private var isSynthesizing = false

    // Word tracking
    private var wordBuffer = ""

    // Spellchecker context
    private let spellDocTag: Int = NSSpellChecker.uniqueSpellDocumentTag()

    // UserDefaults keys
    private let kPrimaryIDKey = "PrimaryInputSourceID"
    private let kSecondaryIDKey = "SecondaryInputSourceID"

    // Primary/Secondary layout IDs (persisted)
    private var primaryID: String {
        get { UserDefaults.standard.string(forKey: kPrimaryIDKey) ?? autoDetectPrimaryID() }
        set { UserDefaults.standard.set(newValue, forKey: kPrimaryIDKey) }
    }
    private var secondaryID: String {
        get { UserDefaults.standard.string(forKey: kSecondaryIDKey) ?? autoDetectSecondaryID() }
        set { UserDefaults.standard.set(newValue, forKey: kSecondaryIDKey) }
    }

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only feel (LSUIElement=true hides Dock/App menu)
        NSApp.setActivationPolicy(.accessory)

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: "Layout")
        statusItem.button?.imagePosition = .imageLeading

        rebuildMenu()
        updateStatusTitleAndColor()

        // Start global key listener (Input Monitoring permission required)
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
        let menu = NSMenu()

        // Toggle
        let toggleItem = NSMenuItem(title: "Toggle Layout", action: #selector(toggleLayout), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Select Layouts… (dynamic)
        let selectItem = NSMenuItem(title: "Select Layouts…", action: nil, keyEquivalent: "")
        let selectMenu = NSMenu(title: "Select Layouts…")
        menu.addItem(selectItem)
        menu.setSubmenu(selectMenu, for: selectItem)

        // Primary section
        let primaryHeader = NSMenuItem(title: "Set as Primary", action: nil, keyEquivalent: "")
        primaryHeader.isEnabled = false
        selectMenu.addItem(primaryHeader)
        for info in listSelectableKeyboardLayouts() {
            let item = NSMenuItem(title: "• \(info.name)", action: #selector(setAsPrimary(_:)), keyEquivalent: "")
            item.representedObject = info.id
            item.target = self
            if info.id == primaryID { item.state = .on }
            selectMenu.addItem(item)
        }

        selectMenu.addItem(NSMenuItem.separator())

        // Secondary section
        let secondaryHeader = NSMenuItem(title: "Set as Secondary", action: nil, keyEquivalent: "")
        secondaryHeader.isEnabled = false
        selectMenu.addItem(secondaryHeader)
        for info in listSelectableKeyboardLayouts() where info.id != primaryID {
            let item = NSMenuItem(title: "• \(info.name)", action: #selector(setAsSecondary(_:)), keyEquivalent: "")
            item.representedObject = info.id
            item.target = self
            if info.id == secondaryID { item.state = .on }
            selectMenu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
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

    // MARK: - Toggle Action

    @objc private func toggleLayout() {
        let current = currentInputSourceID()
        let target = (current == secondaryID) ? primaryID : secondaryID
        switchToInputSource(id: target)
        playSwitchSound()
        updateStatusTitleAndColor()
    }

    // MARK: - Badge (label + color)

    private func updateStatusTitleAndColor() {
        guard let button = statusItem.button else { return }
        let curID = currentInputSourceID()
        let label = shortName(for: curID)
        let isUkr = isLanguage(id: curID, hasPrefix: "uk")

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let color = isUkr ? NSColor.systemBlue : NSColor.labelColor
        button.attributedTitle = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        button.toolTip = fullName(for: curID)
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

    // MARK: - Sound

    private func playSwitchSound() { NSSound.beep() }

    // MARK: - Input Source Helpers (TIS / Carbon)

    private struct InputSourceInfo {
        let id: String
        let name: String
        let languages: [String] // e.g., ["en"], ["uk"], ["mul-Latn"]
    }

    private func listSelectableKeyboardLayouts() -> [InputSourceInfo] {
        let query: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as CFString,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        guard let list = TISCreateInputSourceList(query as CFDictionary, false)?
                .takeRetainedValue() as? [TISInputSource] else {
            return []
        }
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
        // Bridge from opaque pointer → AnyObject (unretained per TIS docs)
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }

    // MARK: - First-run Auto-detect

    private func autoDetectPrimaryID() -> String {
        let current = currentInputSourceID()
        if !current.isEmpty { return current }
        let all = listSelectableKeyboardLayouts()
        if let us = all.first(where: { $0.id == "com.apple.keylayout.US" }) { return us.id }
        if let abc = all.first(where: { $0.id == "com.apple.keylayout.ABC" }) { return abc.id }
        return all.first?.id ?? "com.apple.keylayout.US"
    }

    private func autoDetectSecondaryID() -> String {
        // Use the persisted primaryID rather than auto-detecting again. The previous
        // implementation called `autoDetectPrimaryID()` which inspects the *current*
        // keyboard layout. If the user has changed their primary layout but hasn't
        // switched to it yet, using the current layout could yield the same ID for
        // both primary and secondary layouts. By reading the stored `primaryID` we
        // ensure the secondary layout is chosen relative to the actual primary
        // preference.
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

    // MARK: - Event Tap (Auto-fix wrong layout)

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
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
        return me.handleKeyEvent(type: type, event: event)
    }

    private func handleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if isSynthesizing { return Unmanaged.passUnretained(event) }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Ignore shortcuts (⌘/⌃/⌥)
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return Unmanaged.passUnretained(event)
        }

        // Read typed character
        var buf = [UniChar](repeating: 0, count: 4)
        var len = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        guard len > 0, let scalar = UnicodeScalar(buf[0]) else {
            return Unmanaged.passUnretained(event)
        }

        // Treat letter-ish first:
        // - Latin or Cyrillic letters
        // - OR (when current layout is Latin) ABC-keys that become UA letters: [];',.
        let currentIsLatin = isLayoutLatin(currentInputSourceID())
        if isLatinLetter(scalar) || isCyrillicLetter(scalar) || (currentIsLatin && isMappedLatinPunctuation(scalar)) {
            wordBuffer.unicodeScalars.append(scalar)
            return Unmanaged.passUnretained(event)
        }

        // Boundary => evaluate buffered word, keep the boundary char
        if isBoundary(scalar) {
            processBufferedWordIfNeeded(keepFollowingBoundary: true)
            return Unmanaged.passUnretained(event)
        }

        // Other (digits/symbols) — treat like boundary but keep that char
        processBufferedWordIfNeeded(keepFollowingBoundary: true)
        return Unmanaged.passUnretained(event)
    }


    private func processBufferedWordIfNeeded(keepFollowingBoundary: Bool = false) {
        guard !wordBuffer.isEmpty else { return }

        let curID = currentInputSourceID()
        let curLangPrefix = isLayoutUkrainian(curID) ? "uk" : "en"
        let otherLangPrefix = (curLangPrefix == "en") ? "uk" : "en"
        let suspiciousEN = (curLangPrefix == "en") && containsLetterLikePunct(wordBuffer)

        guard let curSpell = bestSpellLang(for: curLangPrefix),
              let otherSpell = bestSpellLang(for: otherLangPrefix) else {
            wordBuffer = ""
            return
        }

        if !suspiciousEN && isSpelledCorrect(wordBuffer, language: curSpell) {
            wordBuffer = ""
            return
        }

        let converted = convert(wordBuffer, from: curLangPrefix, to: otherLangPrefix)

        var shouldReplace = false

        // Primary rule: converted word is valid in the other language
        if !converted.isEmpty, isSpelledCorrect(converted, language: otherSpell) {
            shouldReplace = true
        } else {
            // Fallback rule: clearly typed on ABC (Latin) using UA positions
            if curLangPrefix == "en", containsLetterLikePunct(wordBuffer), isAllCyrillic(converted) {
                shouldReplace = true
            }
        }
        if shouldReplace {
            replaceLastWord(
                with: converted,
                targetLangPrefix: otherLangPrefix,
                keepFollowingBoundary: keepFollowingBoundary
            )
            playSwitchSound()
            updateStatusTitleAndColor()
        }


        wordBuffer = ""
    }

    // MARK: - Word utils + spellcheck

    private func isBoundary(_ s: UnicodeScalar) -> Bool {
        if isWordInternal(s) { return false } // NEW: keep apostrophes & hyphens inside words
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

    private func bestSpellLang(for prefix: String) -> String? {
        NSSpellChecker.shared.availableLanguages.first { $0.hasPrefix(prefix) }
    }

    private func isSpelledCorrect(_ word: String, language: String) -> Bool {
        let miss = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: spellDocTag,
            wordCount: nil
        )
        return miss.location == NSNotFound
    }

    // MARK: - Replace last word (Accessibility: send keys)

    private enum SpecialKey { case leftArrow, rightArrow }

    private func replaceLastWord(with newWord: String,
                                 targetLangPrefix: String,
                                 keepFollowingBoundary: Bool) {
        let deleteCount = wordBuffer.count

        DispatchQueue.main.async {
            self.isSynthesizing = true

            // If caret is after a boundary (space/punctuation) keep it:
            if keepFollowingBoundary { self.tapKey(.leftArrow) }

            // Delete wrong word
            self.sendBackspace(times: deleteCount)

            // Decide target: prefer language-based, else flip to the other of your pair
            let targetID = self.layoutID(forLanguagePrefix: targetLangPrefix) ?? self.otherLayoutID()

            // Switch & poll until it sticks, then type corrected word
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

    // Switch, then poll until the system reports the target is active
    private func ensureSwitch(to targetID: String, attempts: Int = 12, done: @escaping () -> Void) {
        func attempt(_ n: Int) {
            self.switchToInputSource(id: targetID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if self.currentInputSourceID() == targetID || n >= attempts {
                    done()
                } else {
                    attempt(n + 1)
                }
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
        } else { // "en" or any Latin-like target (ABC often reports mul-Latn)
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
        if langs.contains(where: { $0.localizedCaseInsensitiveContains("latn") }) { return true } // e.g., mul-Latn
        if langs.contains(where: { $0.hasPrefix("mul") }) { return true }
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
    
    // EN→UK letter keys that look like punctuation on ABC
    private let letterLikePunctScalars = Set("[];',.".unicodeScalars)
    private func isMappedLatinPunctuation(_ s: UnicodeScalar) -> Bool {
        letterLikePunctScalars.contains(s)
    }
    
    private func containsLetterLikePunct(_ s: String) -> Bool {
        s.unicodeScalars.contains { letterLikePunctScalars.contains($0) }
    }
    private func isAllCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { isCyrillicLetter($0) }
    }
    
    // Characters that are allowed inside words (don’t break the buffer)
    private let wordInternalScalars = Set("'’-".unicodeScalars) // ASCII ', Unicode ’, hyphen-minus -

    private func isWordInternal(_ s: UnicodeScalar) -> Bool {
        wordInternalScalars.contains(s)
    }

    // EN -> UK (Ukrainian standard)
    private let en2uk: [Character: String] = [
        "q":"й","w":"ц","e":"у","r":"к","t":"е","y":"н","u":"г","i":"ш","o":"щ","p":"з","[":"х","]":"ї",
        "a":"ф","s":"і","d":"в","f":"а","g":"п","h":"р","j":"о","k":"л","l":"д",";":"ж","'":"є",
        "z":"я","x":"ч","c":"с","v":"м","b":"и","n":"т","m":"ь",",":"б",".":"ю","/":"."
    ]

    // UK -> EN (reverse)
    private lazy var uk2en: [Character: String] = {
        var rev: [Character: String] = [:]
        for (k,v) in en2uk { for ch in v { rev[ch] = String(k) } }
        rev["’"] = "'" // apostrophe variant
        return rev
    }()
}
