//
//  LayoutBuddyTests.swift
//  LayoutBuddyTests
//
//  Created by Mykola Melnyk on 10.08.2025.
//

import Testing
import ApplicationServices
@testable import LayoutBuddy
import Carbon
import ApplicationServices

struct LayoutBuddyTests {

    @Test func ukrainianWordConversionProducesAsciiApostrophe() throws {
        let delegate = AppCoordinator()
        let result = delegate.convert("п’ять", from: "uk", to: "en")
        #expect(result == "g'znm")
        #expect(result.contains("'"))
    }

    @Test func testDeleteClearsBufferWithoutConversion() async throws {
        let app = AppCoordinator()

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

    @Test func testAtSymbolSkipsLayoutSwitching() throws {
        let app = AppCoordinator()
        app.test_setWordBuffer("hello")

        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            #expect(Bool(false), "Unable to create CGEvent for testing")
            return
        }

        var at: UniChar = 64 // '@'
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &at)

        let returned = app.test_handleKeyEvent(type: .keyDown, event: event)?.takeUnretainedValue()
        #expect(returned === event)

        // Word buffer should be cleared to avoid layout switching inside email-like strings
        #expect(app.test_getWordBuffer().isEmpty)

        var ch: UniChar = 0
        var len: Int = 0
        returned?.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &len, unicodeString: &ch)
        #expect(len == 1 && ch == at)
    }

    @Test func testEmailAddressRemainsUnchangedAfterSpace() throws {
        let app = AppCoordinator()
        let email = "mr.nicholas.x@gmail.com"

        for scalar in email.unicodeScalars {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                #expect(Bool(false), "Unable to create CGEvent for testing")
                return
            }
            var ch: UniChar = UniChar(scalar.value)
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            _ = app.testHandleKeyEvent(type: .keyDown, event: event)
        }

        // After typing the full email, the internal buffer should remain empty
        #expect(app.testWordBuffer.isEmpty)

        // Typing space should simply pass through and keep buffer empty
        guard let spaceEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            #expect(Bool(false), "Unable to create space CGEvent for testing")
            return
        }
        var space: UniChar = 32
        spaceEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &space)
        let returned = app.testHandleKeyEvent(type: .keyDown, event: spaceEvent)?.takeUnretainedValue()
        #expect(returned === spaceEvent)
        #expect(app.testWordBuffer.isEmpty)
    }
}
