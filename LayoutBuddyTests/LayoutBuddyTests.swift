//
//  LayoutBuddyTests.swift
//  LayoutBuddyTests
//
//  Created by Mykola Melnyk on 10.08.2025.
//

import Testing
import ApplicationServices
@testable import LayoutBuddy

struct LayoutBuddyTests {

    @Test func testAtSymbolSkipsLayoutSwitching() throws {
        let app = AppDelegate()
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
}
