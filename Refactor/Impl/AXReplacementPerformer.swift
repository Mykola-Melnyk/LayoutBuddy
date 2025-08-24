import AppKit

@MainActor
final class AXReplacementPerformer: ReplacementPerformer {
    private let synth = EventSynthesizer()

    func beginSynthesis() {
        synth.begin()
    }

    func endSynthesis() {
        synth.end()
    }

    func synthesizeDeletion(count: Int) {
        synth.backspace(times: count)
    }

    func synthesizeInsertion(_ text: String) {
        synth.typeString(text)
    }
    
    func synthesizeDeleteWordLeft() {
        synth.deleteWordLeft() }

    func replace(in element: AXUIElement, range: TextRange, with text: String) async throws {
        // Set selected text range to our range
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
            throw ReplacementError.unavailableAX("Cannot create AXValue range")
        }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
            throw ReplacementError.unavailableAX("Cannot set selected text range")
        }

        // Set selected text to new content
        let newText = text as CFString
        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText) == .success {
            return
        }

        // Retry small number of times on failure
        for _ in 0..<2 {
            try await Task.sleep(nanoseconds: 60_000_000)
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText) == .success {
                return
            }
        }

        throw ReplacementError.setFailed
    }
}
