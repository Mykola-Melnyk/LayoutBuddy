import Foundation
import ApplicationServices

/// Abstracts the read/write of a focused editable control so the word-edit
/// orchestration can run against either a live Accessibility element or an
/// in-memory fake in tests.
protocol TextTarget: AnyObject {
    /// Full text of the control, or nil if unavailable.
    var text: String? { get }
    /// Current selection; `length == 0` is a plain caret. Nil if unavailable.
    var selection: NSRange? { get }
    /// Replaces the whole value. Returns false if the control rejected the write.
    @discardableResult func write(_ newText: String) -> Bool
    /// Moves the caret / selection. Returns false on failure.
    @discardableResult func select(_ range: NSRange) -> Bool
    /// The backing AX element when one exists (enables precise undo); nil for
    /// non-AX targets such as the test fake.
    var axElement: AXUIElement? { get }
}

/// Production `TextTarget` backed by a live `AXUIElement`. This is the single
/// home for the AX value/selected-range marshalling.
final class AXTextTarget: TextTarget {
    private let element: AXUIElement
    init(element: AXUIElement) { self.element = element }

    var axElement: AXUIElement? { element }

    var text: String? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
           let s = ref as? String { return s }
        return nil
    }

    var selection: NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let val = ref,
              CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        let axVal = val as! AXValue
        var cfr = CFRange(location: 0, length: 0)
        if AXValueGetType(axVal) == .cfRange, AXValueGetValue(axVal, .cfRange, &cfr) {
            return NSRange(location: cfr.location, length: cfr.length)
        }
        return nil
    }

    @discardableResult
    func write(_ newText: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newText as CFTypeRef) == .success
    }

    @discardableResult
    func select(_ range: NSRange) -> Bool {
        var cfr = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &cfr) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }
}
