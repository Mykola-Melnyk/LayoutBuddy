//
//  LayoutBuddyTests.swift
//  LayoutBuddyTests
//
//  Created by Mykola Melnyk on 10.08.2025.
//

import Testing
@testable import LayoutBuddy
import Carbon
import ApplicationServices

struct LayoutBuddyTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func testDeleteClearsBufferWithoutConversion() async throws {
        let app = AppDelegate()

        // Simulate Delete key removing last character
        app.testWordBuffer = "word.x"
        let deleteEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)!
        let resultDelete = app.testHandleKeyEvent(type: .keyDown, event: deleteEvent)
        #expect(app.testWordBuffer == "word.")
        #expect(resultDelete?.takeUnretainedValue() === deleteEvent)

        // Simulate Forward Delete key removing last character
        app.testWordBuffer = "word"
        let forwardDeleteEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ForwardDelete), keyDown: true)!
        let resultForward = app.testHandleKeyEvent(type: .keyDown, event: forwardDeleteEvent)
        #expect(app.testWordBuffer == "wor")
        #expect(resultForward?.takeUnretainedValue() === forwardDeleteEvent)
    }

}
