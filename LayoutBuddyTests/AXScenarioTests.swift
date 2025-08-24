#if canImport(ApplicationServices)
import Cocoa
import ApplicationServices
import Carbon
import Testing
@testable import LayoutBuddy

@MainActor
struct AXScenarioTests {
    @Test func testAXWordReplacement() async throws {
        // Set up window with a focused text view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        let textView = NSTextView(frame: window.contentView!.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = true
        textView.isSelectable = true
        textView.setAccessibilityElement(true)
        window.contentView?.addSubview(textView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        let app = AppCoordinator()
        app.testSetSimulationMode(true)

        // Simulate typing an ambiguous word
        let word = "ghbdsn"
        for scalar in word.unicodeScalars {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                #expect(Bool(false), "Unable to create CGEvent")
                return
            }
            var ch: UniChar = UniChar(scalar.value)
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            textView.insertText(String(scalar), replacementRange: textView.selectedRange())
            _ = app.testHandleKeyEvent(type: .keyDown, event: event)
        }

        // Trigger word processing with a space
        guard let spaceEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            #expect(Bool(false), "Unable to create space event")
            return
        }
        var space: UniChar = 32
        spaceEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &space)
        textView.insertText(" ", replacementRange: textView.selectedRange())
        _ = app.testHandleKeyEvent(type: .keyDown, event: spaceEvent)

        // Wait for captureAmbiguityLater
        try await Task.sleep(nanoseconds: 200_000_000)

        // Apply the ambiguity synchronously
        app.testApplyMostRecentAmbiguitySynchronously()

        // Ensure the text view reflects the converted word
        #expect(textView.string == "привіт ")
    }
}
#endif
