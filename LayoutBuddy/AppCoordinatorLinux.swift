#if os(Linux)
import Foundation

public enum CGEventType {
    case keyDown
    case keyUp
}

public struct CGEventFlags: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let maskCommand   = CGEventFlags(rawValue: 1 << 0)
    public static let maskControl   = CGEventFlags(rawValue: 1 << 1)
    public static let maskAlternate = CGEventFlags(rawValue: 1 << 2)
    public static let maskShift     = CGEventFlags(rawValue: 1 << 3)
}

public struct CGEventField: RawRepresentable, Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let keyboardEventKeycode = CGEventField(rawValue: 0)
}

public typealias UniChar = UInt16
public typealias CGKeyCode = UInt16

public class CGEvent {
    public var type: CGEventType
    public var flags: CGEventFlags = []
    private var unicode: [UniChar] = []
    private var keycode: CGKeyCode

    public init?(keyboardEventSource: Any?, virtualKey: CGKeyCode, keyDown: Bool) {
        self.type = keyDown ? .keyDown : .keyUp
        self.keycode = virtualKey
    }

    public func keyboardSetUnicodeString(stringLength: Int, unicodeString: inout UniChar) {
        unicode = [unicodeString]
    }

    public func keyboardGetUnicodeString(maxStringLength: Int, actualStringLength: inout Int, unicodeString: inout [UniChar]) {
        let count = min(maxStringLength, unicode.count)
        actualStringLength = count
        unicodeString = Array(unicode.prefix(count))
    }

    public func keyboardGetUnicodeString(maxStringLength: Int, actualStringLength: inout Int, unicodeString: inout UniChar) {
        var arr = [unicodeString]
        keyboardGetUnicodeString(maxStringLength: maxStringLength, actualStringLength: &actualStringLength, unicodeString: &arr)
        unicodeString = arr.first ?? 0
    }

    public func getIntegerValueField(_ field: CGEventField) -> Int64 {
        Int64(keycode)
    }

    public func copy() -> CGEvent? {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: type == .keyDown)
        var ch = unicode.first ?? 0
        e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
        e?.flags = flags
        return e
    }
}

public let kVK_Delete: Int32 = 51
public let kVK_ForwardDelete: Int32 = 117
public let kVK_Space: Int32 = 49

public final class AppCoordinator {
    private var wordParser = WordParser()
    private var inEmail = false
    private var isSynthesizing = false {
        didSet { if !isSynthesizing { flushQueuedEvents() } }
    }
    private var queuedEvents: [CGEvent] = []
    private let queuedEventsLock = NSLock()

    public init() {}

#if DEBUG
    // Test capture buffer
    private var test_isCapturing = false
    private var test_captureText: String = ""
    private var test_lastDeletionCount: Int = 0
    private var test_lastInserted: String? = nil
#endif

    // MARK: - Conversion
    public func convert(_ word: String, from src: String, to dst: String) -> String {
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
        rev["’"] = "'"
        return rev
    }()

    // MARK: - Event handling
    @MainActor private func handleKeyEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if isSynthesizing {
            if let copy = event.copy() { enqueueQueuedEvent(copy) }
            return nil
        }
        guard event.type == .keyDown else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let hasAlt = flags.contains(.maskAlternate)
        let hasCtrl = flags.contains(.maskControl)
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if hasCtrl && hasAlt && keyCode == CGKeyCode(kVK_Space) {
            let word = wordParser.buffer
            if !word.isEmpty {
                let converted: String
                if let first = word.unicodeScalars.first, wordParser.isLatinLetter(first) {
                    converted = convert(word, from: "en", to: "uk")
                } else {
                    converted = convert(word, from: "uk", to: "en")
                }
                testNotifyDidDeleteBackward(word.count)
                testNotifyDidTypeText(converted)
                wordParser.clear()
            }
            return Unmanaged.passUnretained(event)
        }

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
                wordParser.clear()
            }
            return Unmanaged.passUnretained(event)
        }

        if scalar == UnicodeScalar(64) { // '@'
            wordParser.clear()
            inEmail = true
            return Unmanaged.passUnretained(event)
        }

        if let first = wordParser.buffer.unicodeScalars.first {
            let firstIsLatin = wordParser.isLatinLetter(first)
            let newIsLatin = wordParser.isLatinLetter(scalar)
            if firstIsLatin != newIsLatin {
                wordParser.clear()
            }
        }

        if wordParser.isLatinLetter(scalar) || wordParser.isCyrillicLetter(scalar) || wordParser.isMappedLatinPunctuation(scalar) {
            wordParser.append(character: scalar)
        } else if wordParser.isBoundary(scalar) {
            wordParser.clear()
        } else {
            wordParser.clear()
        }

        return Unmanaged.passUnretained(event)
    }

    private func enqueueQueuedEvent(_ event: CGEvent) {
        queuedEventsLock.lock()
        queuedEvents.append(event)
        queuedEventsLock.unlock()
    }

    private func flushQueuedEvents() {
        queuedEventsLock.lock()
        queuedEvents.removeAll()
        queuedEventsLock.unlock()
    }

    // MARK: - Testing helpers
    public var testWordBuffer: String {
        get { wordParser.test_getBuffer() }
        set { wordParser.test_setBuffer(newValue) }
    }

    @MainActor public func testHandleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        handleKeyEvent(event)
    }

    public func testSetSynthesizing(_ value: Bool) {
        isSynthesizing = value
    }

    public func testQueuedEventsCount() -> Int {
        queuedEventsLock.lock(); defer { queuedEventsLock.unlock() }
        return queuedEvents.count
    }

    @MainActor public func testBeginCaptureBuffer() {
        test_captureText = ""
        test_lastDeletionCount = 0
        test_lastInserted = nil
        test_isCapturing = true
    }

    @MainActor public func testCapturedText() -> String { test_captureText }
    @MainActor public func testLastDeletionCount() -> Int { test_lastDeletionCount }
    @MainActor public func testLastInserted() -> String? { test_lastInserted }

    @MainActor public func testNotifyDidDeleteBackward(_ times: Int) {
        guard test_isCapturing, times > 0 else { return }
        test_lastDeletionCount = times
        if !test_captureText.isEmpty {
            let end = test_captureText.endIndex
            let start = test_captureText.index(end, offsetBy: -min(times, test_captureText.count))
            test_captureText.removeSubrange(start..<end)
        }
    }

    @MainActor public func testNotifyDidTypeText(_ text: String) {
        guard test_isCapturing else { return }
        test_lastInserted = text
        test_captureText.append(text)
    }

    @MainActor public func testAppendRawKeystroke(_ scalar: UniChar) {
        guard test_isCapturing, let uni = UnicodeScalar(scalar) else { return }
        test_captureText.append(Character(uni))
    }
}
#endif
