//
//  LayoutBuddyTests.swift
//  LayoutBuddyTests
//
//  Created by Mykola Melnyk on 10.08.2025.
//

import Testing
@testable import LayoutBuddy

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(Carbon)
import Carbon
#endif

import Foundation

struct LayoutBuddyTests {
    
    @Test func testEnglishInputProducesUkrainianOutput() throws {
            let app = AppCoordinator()
            #expect(app.convert("ghbdsn", from: "en", to: "uk") == "привіт")
        }
    
    @Test func testEnglishWithCommaAndRealWordInputProducesUkrainianOutput() throws {
            let app = AppCoordinator()
            #expect(app.convert(",elm", from: "en", to: "uk") == "будь")
        }

    @Test func testUkrainianInputProducesEnglishOutput() throws {
            let app = AppCoordinator()
            #expect(app.convert("руддщ", from: "uk", to: "en") == "hello")
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
        app.testWordBuffer = "hello"

        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            #expect(Bool(false), "Unable to create CGEvent for testing")
            return
        }

        var at: UniChar = 64 // '@'
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &at)

        let returned = app.testHandleKeyEvent(type: .keyDown, event: event)?.takeUnretainedValue()
        #expect(returned === event)

        // Word buffer should be cleared to avoid layout switching inside email-like strings
        #expect(app.testWordBuffer.isEmpty)

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

    @Test func testScriptChangeStartsNewWord() throws {
        let app = AppCoordinator()

        // Type an English word
        for scalar in "hello".unicodeScalars {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                #expect(Bool(false), "Unable to create CGEvent for testing")
                return
            }
            var ch: UniChar = UniChar(scalar.value)
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            _ = app.testHandleKeyEvent(type: .keyDown, event: event)
        }

        // Follow with a Cyrillic letter that should start a new word
        guard let shchEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            #expect(Bool(false), "Unable to create Cyrillic CGEvent for testing")
            return
        }
        var shch: UniChar = 0x0449 // 'щ'
        shchEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &shch)
        _ = app.testHandleKeyEvent(type: .keyDown, event: shchEvent)
        #expect(app.testWordBuffer == String(UnicodeScalar(0x0449)!))

        // Typing space should clear the buffer
        guard let spaceEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            #expect(Bool(false), "Unable to create space CGEvent for testing")
            return
        }
        var space: UniChar = 32
        spaceEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &space)
        _ = app.testHandleKeyEvent(type: .keyDown, event: spaceEvent)
        #expect(app.testWordBuffer.isEmpty)

        // Now a Ukrainian word followed by a Latin letter
        for scalar in "привіт".unicodeScalars {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                #expect(Bool(false), "Unable to create CGEvent for testing")
                return
            }
            var ch: UniChar = UniChar(scalar.value)
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            _ = app.testHandleKeyEvent(type: .keyDown, event: event)
        }

        guard let nEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            #expect(Bool(false), "Unable to create Latin CGEvent for testing")
            return
        }
        var n: UniChar = 110 // 'n'
        nEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &n)
        _ = app.testHandleKeyEvent(type: .keyDown, event: nEvent)
        #expect(app.testWordBuffer == "n")
    }

    @Test func testBufferedEventsDuringSynthesis() throws {
        let app = AppCoordinator()
        app.testSetSynthesizing(true)

        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            #expect(Bool(false), "Unable to create CGEvent for testing")
            return
        }
        var ch: UniChar = 97 // 'a'
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)

        let result = app.testHandleKeyEvent(type: .keyDown, event: event)
        #expect(result == nil)
        #expect(app.testQueuedEventsCount() == 1)

        app.testSetSynthesizing(false)
        #expect(app.testQueuedEventsCount() == 0)
    }

    @Test func testHotkeyAppliesAmbiguityToMostRecentWord() throws {
        let app = AppCoordinator()
        app.testSetSimulationMode(true)
        // Simulate having typed: "the best cat" with English layout
        app.testDocumentText = "the best cat"

        // Seed an ambiguity for the word "the" that should convert to Ukrainian-position mapping "еру".
        // Since two words were typed after it ("best", "cat"), wordsAhead is 2.
        app.testPushAmbiguity(original: "the", converted: "еру", targetLangPrefix: "uk", wordsAhead: 2)

        // Apply the most recent ambiguity synchronously for deterministic assert.
        app.testApplyMostRecentAmbiguitySynchronously()

        // Verify only the first word is converted.
        #expect(app.testDocumentText == "еру best cat")
    }
}
