import Cocoa
import ApplicationServices
#if canImport(Carbon)
import Carbon.HIToolbox
#else
let kVK_Delete: UInt16 = 51
let kVK_ForwardDelete: UInt16 = 117
let kVK_LeftArrow: UInt16 = 123
let kVK_RightArrow: UInt16 = 124
#endif

/// Centralised key event processing. Maintains a `WordParser` and delegates
/// spell‑checking and auto‑fixing to specialised services.
final class KeyHandler {
    private let layoutManager: KeyboardLayoutManager
    private let autoFixer: AutoFixer

    let wordParser = WordParser()
    private var inEmail = false

    // Event synthesising support
    var isSynthesizing = false {
        didSet { if !isSynthesizing { flushQueuedEvents() } }
    }
    private var queuedEvents: [CGEvent] = []
    private let queuedEventsLock = NSLock()
    private let isRunningUnitTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init(layoutManager: KeyboardLayoutManager, autoFixer: AutoFixer) {
        self.layoutManager = layoutManager
        self.autoFixer = autoFixer
    }

    func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        if isSynthesizing {
            if let copy = event.copy() { enqueueQueuedEvent(copy) }
            return nil
        }
        guard event.type == .keyDown else { return Unmanaged.passUnretained(event) }

        let flags   = event.flags
        let hasCmd  = flags.contains(.maskCommand)
        let hasCtrl = flags.contains(.maskControl)
        let hasAlt  = flags.contains(.maskAlternate)
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if hasCmd || hasCtrl { return Unmanaged.passUnretained(event) }

        if keyCode == CGKeyCode(kVK_Delete) || keyCode == CGKeyCode(kVK_ForwardDelete) {
            if hasAlt {
                wordParser.clear()
            } else if !wordParser.buffer.isEmpty {
                wordParser.removeLast()
            }
            return Unmanaged.passUnretained(event)
        }

        var buf = [UniChar](repeating: 0, count: 4)
        var len = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        guard len > 0, let scalar = UnicodeScalar(buf[0]) else {
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
            if let first = wordParser.buffer.unicodeScalars.first {
                let firstIsLatin = wordParser.isLatinLetter(first) || wordParser.isMappedLatinPunctuation(first)
                let newIsLatin = wordParser.isLatinLetter(scalar) || (currentIsLatin && wordParser.isMappedLatinPunctuation(scalar))
                if firstIsLatin != newIsLatin {
                    processBufferedWordIfNeeded()
                    bumpWordsAhead()
                }
            }
            wordParser.append(character: scalar)
            return Unmanaged.passUnretained(event)
        }

        if wordParser.isBoundary(scalar) {
            processBufferedWordIfNeeded(keepFollowingBoundary: true)
            bumpWordsAhead()
            return Unmanaged.passUnretained(event)
        }

        processBufferedWordIfNeeded(keepFollowingBoundary: true)
        bumpWordsAhead()
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Processing helpers

    private func processBufferedWordIfNeeded(keepFollowingBoundary: Bool = false) {
        guard !wordParser.buffer.isEmpty else { return }
        let curID = layoutManager.currentInputSourceID()
        let curLangPrefix = isLayoutUkrainian(curID) ? "uk" : "en"
        let (core, trailingCount) = wordParser.splitTrailingMapped(wordParser.buffer)
        if let fix = autoFixer.autoFix(word: core, currentLangPrefix: curLangPrefix) {
            let trailing = String(wordParser.buffer.suffix(trailingCount))
            let newWord = fix.converted + trailing
            replaceLastWord(with: newWord,
                            targetLangPrefix: fix.targetLang,
                            keepFollowingBoundary: keepFollowingBoundary)
        }
        wordParser.clear()
    }

    private func bumpWordsAhead() {
        // Placeholder for ambiguity tracking. Intentionally left blank.
    }

    // MARK: - Event queue helpers

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

        if isRunningUnitTests { return }
        for e in events {
            e.post(tap: .cgAnnotatedSessionEventTap)
            if let up = e.copy() {
                up.type = .keyUp
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    // MARK: - Layout helpers
    private func isLayoutUkrainian(_ id: String) -> Bool {
        if layoutManager.isLanguage(id: id, hasPrefix: "uk") { return true }
        let name = layoutManager.inputSourceInfo(for: id)?.name.lowercased() ?? ""
        return name.contains("ukrainian") || name.contains("україн")
    }

    private func isLayoutLatin(_ id: String) -> Bool {
        let langs = layoutManager.inputSourceInfo(for: id)?.languages ?? []
        if langs.contains(where: { $0.hasPrefix("en") }) { return true }
        if langs.contains(where: { $0.localizedCaseInsensitiveContains("latn") }) { return true }
        if langs.contains(where: { $0.hasPrefix("mul") }) { return true }
        let name = layoutManager.inputSourceInfo(for: id)?.name.lowercased() ?? ""
        if name.contains("abc") || name.contains("u.s.") || name == "us" { return true }
        let idLower = id.lowercased()
        if idLower.contains("com.apple.keylayout.abc") || idLower.contains("com.apple.keylayout.us") { return true }
        return false
    }

    // MARK: - Testing helpers
    func testQueuedEventsCount() -> Int {
        queuedEventsLock.lock(); defer { queuedEventsLock.unlock() }
        return queuedEvents.count
    }

    // MARK: - Replacement helpers

    private enum SpecialKey { case leftArrow, rightArrow }

    private func replaceLastWord(with newWord: String,
                                 targetLangPrefix: String,
                                 keepFollowingBoundary: Bool) {
        let deleteCount = wordParser.buffer.count
        DispatchQueue.main.async {
            self.isSynthesizing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if keepFollowingBoundary { self.tapKey(.leftArrow) }
                self.sendBackspace(times: deleteCount)
                self.ensureSwitch(to: targetLangPrefix) {
                    self.typeUnicode(newWord)
                    if keepFollowingBoundary { self.tapKey(.rightArrow) }
                    self.isSynthesizing = false
                }
            }
        }
    }

    private func ensureSwitch(to targetLangPrefix: String, completion: @escaping () -> Void) {
        let curIsUkr = isLayoutUkrainian(layoutManager.currentInputSourceID())
        let needUkr = (targetLangPrefix == "uk")
        if curIsUkr != needUkr {
            layoutManager.toggleLayout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: completion)
        } else {
            completion()
        }
    }

    private func sendBackspace(times: Int) {
        if isRunningUnitTests { return }
        guard times > 0 else { return }
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vk = CGKeyCode(kVK_Delete)
        for _ in 0..<times {
            CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)?.post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func tapKey(_ key: SpecialKey) {
        if isRunningUnitTests { return }
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vk: CGKeyCode = {
            switch key {
            case .leftArrow: return CGKeyCode(kVK_LeftArrow)
            case .rightArrow: return CGKeyCode(kVK_RightArrow)
            }
        }()
        CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)?.post(tap: .cgAnnotatedSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func typeUnicode(_ text: String) {
        if isRunningUnitTests { return }
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
}

