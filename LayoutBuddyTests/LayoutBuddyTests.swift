import Carbon
import CoreGraphics
import XCTest
@testable import LayoutBuddy

@MainActor
final class LayoutBuddyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppCoordinator().testSetSimulationMode(true)
    }

    func testEnglishInputProducesUkrainianOutput() {
        let app = makeApp()

        XCTAssertEqual(app.convert("ghbdsn", from: "en", to: "uk"), "привіт")
    }

    func testEnglishWithCommaAndRealWordInputProducesUkrainianOutput() {
        let app = makeApp()

        XCTAssertEqual(app.convert(",elm", from: "en", to: "uk"), "будь")
    }

    func testUkrainianInputProducesEnglishOutput() {
        let app = makeApp()

        XCTAssertEqual(app.convert("руддщ", from: "uk", to: "en"), "hello")
    }

    func testConversionPreservesCase() {
        let app = makeApp()

        XCTAssertEqual(app.convert("Ghbdsn", from: "en", to: "uk"), "Привіт")
        XCTAssertEqual(app.convert("Руддщ", from: "uk", to: "en"), "Hello")
    }

    func testConversionRoundTrips() {
        let app = makeApp()

        let typed = "ghbdsn"
        let cyr = app.convert(typed, from: "en", to: "uk")
        XCTAssertEqual(app.convert(cyr, from: "uk", to: "en"), typed)
    }

    func testGheWithUpturnKeyMapping() {
        let app = makeApp()

        XCTAssertEqual(app.convert("\\", from: "en", to: "uk"), "ґ")
        XCTAssertEqual(app.convert("ґ", from: "uk", to: "en"), "\\")
    }

    func testUnmappedCharactersPassThroughUnchanged() {
        let app = makeApp()

        // Digits and unsupported language pairs leave text untouched.
        XCTAssertEqual(app.convert("123", from: "en", to: "uk"), "123")
        XCTAssertEqual(app.convert("hello", from: "en", to: "fr"), "hello")
    }

    // MARK: - WordReplacementPlanner (pure index/string geometry)

    private func planReplace(_ text: String, caret: Int, original: String,
                             converted: String, boundary: UnicodeScalar? = nil,
                             radius: Int = 8) -> WordReplacementPlanner.Plan? {
        WordReplacementPlanner.planReplacement(
            fullText: text as NSString, caret: caret,
            original: original, converted: converted,
            boundaryToInsert: boundary, contextRadius: radius)
    }

    func testPlanBakesSwallowedBoundary() {
        // Normal boundary (space) was swallowed and must be reinserted.
        let plan = planReplace("ghbdsn", caret: 6, original: "ghbdsn", converted: "привіт", boundary: " ")
        XCTAssertEqual(plan?.newText, "привіт ")
        XCTAssertEqual(plan?.newCaret, 7)
        XCTAssertEqual(plan?.correctedRange, NSRange(location: 0, length: 6))
    }

    func testPlanLeavesExistingBoundary() {
        // Special boundary (Enter) already in the document; gap == 1, none baked.
        let plan = planReplace("ghbdsn\n", caret: 7, original: "ghbdsn", converted: "привіт")
        XCTAssertEqual(plan?.newText, "привіт\n")
        XCTAssertEqual(plan?.newCaret, 7)
    }

    func testPlanMidWordHasNoBoundary() {
        let plan = planReplace("ghbdsn", caret: 6, original: "ghbdsn", converted: "привіт")
        XCTAssertEqual(plan?.newText, "привіт")
        XCTAssertEqual(plan?.newCaret, 6)
    }

    func testPlanReplacesWordWithPrecedingText() {
        let plan = planReplace("hello ghbdsn", caret: 12, original: "ghbdsn", converted: "привіт", boundary: " ")
        XCTAssertEqual(plan?.newText, "hello привіт ")
        XCTAssertEqual(plan?.newCaret, 13)
        XCTAssertEqual(plan?.correctedRange, NSRange(location: 6, length: 6))
        XCTAssertEqual(plan?.before, "hello ")
        XCTAssertEqual(plan?.after, " ")
    }

    func testPlanPicksMostRecentOccurrence() {
        // `.backwards` search must target the just-typed word, not an earlier one.
        let plan = planReplace("ghbdsn ghbdsn", caret: 13, original: "ghbdsn", converted: "привіт")
        XCTAssertEqual(plan?.newText, "ghbdsn привіт")
        XCTAssertEqual(plan?.correctedRange, NSRange(location: 7, length: 6))
    }

    func testPlanRefusesWhenLettersSitBetweenWordAndCaret() {
        // A letter in the "gap" means we'd corrupt text — must bail (→ keystroke fallback).
        XCTAssertNil(planReplace("ghbdsnx", caret: 7, original: "ghbdsn", converted: "привіт"))
    }

    func testPlanAllowsTwoCharBoundaryGapButNotThree() {
        XCTAssertNotNil(planReplace("ghbdsn. ", caret: 8, original: "ghbdsn", converted: "привіт"))
        XCTAssertNil(planReplace("ghbdsn   ", caret: 9, original: "ghbdsn", converted: "привіт"))
    }

    func testPlanRefusesWhenCaretBeforeWordStart() {
        XCTAssertNil(planReplace("ghbdsn", caret: 3, original: "ghbdsn", converted: "привіт"))
    }

    func testPlanLastWordConvertsTrailingWord() {
        let plan = WordReplacementPlanner.planLastWord(
            fullText: "hello ghbdsn" as NSString, caret: 12,
            convert: { $0 == "ghbdsn" ? "привіт" : $0 }, contextRadius: 8)
        XCTAssertEqual(plan?.newText, "hello привіт")
        XCTAssertEqual(plan?.correctedRange, NSRange(location: 6, length: 6))
    }

    func testPlanLastWordSkipsTrailingBoundary() {
        let plan = WordReplacementPlanner.planLastWord(
            fullText: "ghbdsn " as NSString, caret: 7,
            convert: { $0 == "ghbdsn" ? "привіт" : $0 }, contextRadius: 8)
        XCTAssertEqual(plan?.newText, "привіт ")
        XCTAssertEqual(plan?.newCaret, 7)
    }

    func testPlanLastWordTreatsApostropheAsWordInternal() {
        let plan = WordReplacementPlanner.planLastWord(
            fullText: "qwe'rty" as NSString, caret: 7,
            convert: { $0.uppercased() }, contextRadius: 8)
        XCTAssertEqual(plan?.original, "qwe'rty")
        XCTAssertEqual(plan?.newText, "QWE'RTY")
    }

    func testPlanLastWordNilWhenConversionIsNoOp() {
        let plan = WordReplacementPlanner.planLastWord(
            fullText: "hello" as NSString, caret: 5,
            convert: { $0 }, contextRadius: 8)
        XCTAssertNil(plan)
    }

    func testAdjustedCaretInsideAndAfterReplacedRange() {
        // Caret inside the replaced word clamps to the new word length.
        XCTAssertEqual(
            WordReplacementPlanner.adjustedCaret(3, afterReplacing: NSRange(location: 0, length: 6), withLength: 4), 3)
        // Caret after the word shifts by the length delta.
        XCTAssertEqual(
            WordReplacementPlanner.adjustedCaret(10, afterReplacing: NSRange(location: 2, length: 3), withLength: 5), 12)
    }

    func testDeleteClearsBufferWithoutConversion() throws {
        let app = makeApp()

        app.testWordBuffer = "word.x"
        let deleteEvent = try keyEvent(keyCode: CGKeyCode(kVK_Delete))
        let resultDelete = app.testHandleKeyEvent(type: .keyDown, event: deleteEvent)
        XCTAssertEqual(app.testWordBuffer, "word.")
        XCTAssertTrue(resultDelete?.takeUnretainedValue() === deleteEvent)

        app.testWordBuffer = "word"
        let forwardDeleteEvent = try keyEvent(keyCode: CGKeyCode(kVK_ForwardDelete))
        let resultForward = app.testHandleKeyEvent(type: .keyDown, event: forwardDeleteEvent)
        XCTAssertTrue(app.testWordBuffer.isEmpty)
        XCTAssertTrue(resultForward?.takeUnretainedValue() === forwardDeleteEvent)
    }

    func testAtSymbolSkipsLayoutSwitching() throws {
        let app = makeApp()
        app.testWordBuffer = "hello"
        let event = try keyEvent(character: "@")

        let returned = app.testHandleKeyEvent(type: .keyDown, event: event)?.takeUnretainedValue()

        XCTAssertTrue(returned === event)
        XCTAssertTrue(app.testWordBuffer.isEmpty)
        XCTAssertEqual(try firstCharacterCode(from: event), UniChar(64))
    }

    func testEmailAddressRemainsUnchangedAfterSpace() throws {
        let app = makeApp()

        try type("mr.nicholas.x@gmail.com", into: app)

        XCTAssertTrue(app.testWordBuffer.isEmpty)

        let spaceEvent = try keyEvent(character: " ")
        let returned = app.testHandleKeyEvent(type: .keyDown, event: spaceEvent)?.takeUnretainedValue()
        XCTAssertTrue(returned === spaceEvent)
        XCTAssertTrue(app.testWordBuffer.isEmpty)
    }

    func testScriptChangeStartsNewWord() throws {
        let app = makeApp()

        try type("hello", into: app)
        _ = app.testHandleKeyEvent(type: .keyDown, event: try keyEvent(character: "щ"))
        XCTAssertEqual(app.testWordBuffer, "щ")

        _ = app.testHandleKeyEvent(type: .keyDown, event: try keyEvent(character: " "))
        XCTAssertTrue(app.testWordBuffer.isEmpty)

        try type("привіт", into: app)
        _ = app.testHandleKeyEvent(type: .keyDown, event: try keyEvent(character: "n"))
        XCTAssertEqual(app.testWordBuffer, "n")
    }

    func testBufferedEventsDuringSynthesis() throws {
        let app = makeApp()
        app.testSetSynthesizing(true)

        let event = try keyEvent(character: "a")
        let result = app.testHandleKeyEvent(type: .keyDown, event: event)

        XCTAssertNil(result)
        XCTAssertEqual(app.testQueuedEventsCount(), 1)

        app.testSetSynthesizing(false)
        XCTAssertEqual(app.testQueuedEventsCount(), 0)
    }

    func testSyntheticRestoredTextDoesNotEnterWordBuffer() throws {
        let app = makeApp()

        for character in "csv" {
            let event = try keyEvent(character: character)
            app.testMarkSynthetic(event)
            let returned = app.testHandleKeyEvent(type: .keyDown, event: event)?.takeUnretainedValue()

            XCTAssertTrue(returned === event)
        }

        XCTAssertTrue(app.testWordBuffer.isEmpty)
    }

    func testHotkeyAppliesAmbiguityToMostRecentWord() {
        let app = makeApp()
        app.testDocumentText = "the best cat"
        app.testPushAmbiguity(original: "the", converted: "еру", targetLangPrefix: "uk", wordsAhead: 2)

        app.testApplyMostRecentAmbiguitySynchronously()

        XCTAssertEqual(app.testDocumentText, "еру best cat")
    }

    func testUndoHotkeyRestoresLastAmbiguousCorrection() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = LayoutPreferences(defaults: defaults)
        let app = makeApp(preferences: prefs)
        app.testDocumentText = "the best cat"
        app.testPushAmbiguity(original: "the", converted: "еру", targetLangPrefix: "uk", wordsAhead: 2)
        app.testApplyMostRecentAmbiguitySynchronously()
        XCTAssertEqual(app.testDocumentText, "еру best cat")

        let event = try keyEvent(
            keyCode: prefs.undoCorrectionHotkey.keyCode,
            flags: CGEventFlags(rawValue: UInt64(prefs.undoCorrectionHotkey.modifiers.rawValue))
        )
        let result = app.testHandleKeyEvent(type: .keyDown, event: event)

        XCTAssertNil(result)
        XCTAssertEqual(app.testDocumentText, "the best cat")
    }

    func testShortcutTogglesConversion() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = LayoutPreferences(defaults: defaults)
        let app = makeApp(preferences: prefs)
        let event = try keyEvent(
            keyCode: prefs.toggleHotkey.keyCode,
            flags: CGEventFlags(rawValue: UInt64(prefs.toggleHotkey.modifiers.rawValue))
        )

        XCTAssertTrue(app.testConversionOn)

        _ = app.testHandleKeyEvent(type: .keyDown, event: event)
        XCTAssertFalse(app.testConversionOn)

        _ = app.testHandleKeyEvent(type: .keyDown, event: event)
        XCTAssertTrue(app.testConversionOn)
    }

    func testUAWordFollowedByExclamationConvertsAndKeepsPunctuation() throws {
        let app = makeApp()

        try type("цщклі", into: app)
        _ = app.testHandleKeyEvent(type: .keyDown, event: try keyEvent(character: "!"))

        XCTAssertEqual(app.testCapturedText(), "works!")
    }

    func testUndoRestoresAutomaticCorrectionBeforePunctuation() throws {
        let app = makeApp()

        try type("цщклі", into: app)
        _ = app.testHandleKeyEvent(type: .keyDown, event: try keyEvent(character: "!"))
        XCTAssertEqual(app.testCapturedText(), "works!")

        app.testUndoLastCorrectionSynchronously()

        XCTAssertEqual(app.testCapturedText(), "цщклі!")
    }

    func testConvertAmbiguousHotkeyRestoresLastAutomaticCorrectionWhenNoAmbiguityExists() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = LayoutPreferences(defaults: defaults)
        let app = makeApp(preferences: prefs)

        try type("цщклі", into: app)
        _ = app.testHandleKeyEvent(type: .keyDown, event: try keyEvent(character: "!"))
        XCTAssertEqual(app.testCapturedText(), "works!")

        let event = try keyEvent(
            keyCode: prefs.convertHotkey.keyCode,
            flags: CGEventFlags(rawValue: UInt64(prefs.convertHotkey.modifiers.rawValue))
        )
        let result = app.testHandleKeyEvent(type: .keyDown, event: event)

        XCTAssertNil(result)
        XCTAssertEqual(app.testCapturedText(), "цщклі!")
    }

    func testCursorNavigationClearsCurrentWordBuffer() throws {
        let app = makeApp()

        try type("цщклі", into: app)
        XCTAssertEqual(app.testWordBuffer, "цщклі")

        let leftArrow = try keyEvent(keyCode: CGKeyCode(kVK_LeftArrow))
        let result = app.testHandleKeyEvent(type: .keyDown, event: leftArrow)

        XCTAssertTrue(result?.takeUnretainedValue() === leftArrow)
        XCTAssertTrue(app.testWordBuffer.isEmpty)
    }

    func testMidWordEditDoesNotConvertBufferedWord() throws {
        let app = makeApp()

        try type("цщклі", into: app)
        app.testSetEditingInsideWordBeforeInput(true)

        let editEvent = try keyEvent(character: "a")
        let editResult = app.testHandleKeyEvent(type: .keyDown, event: editEvent)

        XCTAssertTrue(editResult?.takeUnretainedValue() === editEvent)
        XCTAssertTrue(app.testWordBuffer.isEmpty)

        app.testSetEditingInsideWordBeforeInput(false)
        let boundaryEvent = try keyEvent(character: "!")
        let boundaryResult = app.testHandleKeyEvent(type: .keyDown, event: boundaryEvent)

        XCTAssertTrue(boundaryResult?.takeUnretainedValue() === boundaryEvent)
        XCTAssertEqual(app.testCapturedText(), "")
    }

    private func makeApp(preferences: LayoutPreferences = LayoutPreferences()) -> AppCoordinator {
        let app = AppCoordinator(preferences: preferences)
        app.testSetSimulationMode(true)
        return app
    }

    private func type(_ text: String, into app: AppCoordinator) throws {
        for character in text {
            _ = app.testHandleKeyEvent(type: .keyDown, event: try keyEvent(character: character))
        }
    }

    private func keyEvent(character: Character? = nil, keyCode: CGKeyCode = 0, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        event.flags = flags
        if let scalar = character?.unicodeScalars.first {
            var value = UniChar(scalar.value)
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
        }
        return event
    }

    private func firstCharacterCode(from event: CGEvent) throws -> UniChar {
        var value: UniChar = 0
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &length, unicodeString: &value)
        XCTAssertEqual(length, 1)
        return value
    }
}
