import AppKit

@MainActor
final class AXTextCapture: TextCapture {
    private let boundaries = WordBoundaries()

    func captureWord(at anchor: CaretAnchor) async throws -> TextContext {
        // Get the system-wide accessibility object
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let errFocus = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard errFocus == .success, let element = focused as? AXUIElement else {
            throw TextCaptureError.noFocusedElement
        }

        // Ensure element is editable, if attribute exists
        var editableValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXEditableAttribute as CFString, &editableValue) == .success {
            if let isEditable = editableValue as? Bool, !isEditable {
                throw TextCaptureError.notEditable
            }
        }

        // Get selected text range in UTF16 (CFRange)
        var selectedRangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
              let axRange = selectedRangeValue as? AXValue,
              AXValueGetType(axRange) == .cfRange else {
            throw TextCaptureError.noSelection
        }
        var cfRange = CFRange()
        AXValueGetValue(axRange, .cfRange, &cfRange)
        let caretUTF16 = cfRange.location

        // Obtain full text
        var fullTextValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fullTextValue) == .success,
              let fullText = fullTextValue as? String else {
            throw TextCaptureError.cannotReadText
        }

        // Compute word range using helper
        guard let wordRange = boundaries.currentWordRangeUTF16(in: fullText, caretUTF16: caretUTF16) else {
            throw TextCaptureError.noWord
        }

        // Extract the word via UTF16 indices
        let utf16 = fullText.utf16
        let startIndex = utf16.index(utf16.startIndex, offsetBy: wordRange.location)
        let endIndex = utf16.index(startIndex, offsetBy: wordRange.length)
        let word = String(utf16[startIndex..<endIndex]) ?? ""

        return TextContext(
            element: element,
            fullText: fullText,
            range: wordRange,
            word: word,
            caretUTF16: caretUTF16
        )
    }
}
