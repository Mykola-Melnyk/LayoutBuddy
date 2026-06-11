import ApplicationServices
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

    // MARK: - AX shell (replaceWord/correctLastWord on an in-memory TextTarget)

    func testReplaceWordOnTargetBakesBoundaryAndMovesCaret() {
        let app = makeApp()
        let target = FakeTextTarget("ghbdsn", caret: 6)
        let ok = app.replaceWord(on: target, original: "ghbdsn", converted: "привіт",
                                 boundaryToInsert: " ", restoreLangPrefix: "en")
        XCTAssertTrue(ok)
        XCTAssertEqual(target.text, "привіт ")
        XCTAssertEqual(target.selection, NSRange(location: 7, length: 0))
        XCTAssertEqual(target.writeCount, 1)
    }

    func testReplaceWordOnTargetWithPrecedingText() {
        let app = makeApp()
        let target = FakeTextTarget("hello ghbdsn", caret: 12)
        XCTAssertTrue(app.replaceWord(on: target, original: "ghbdsn", converted: "привіт",
                                      boundaryToInsert: nil, restoreLangPrefix: "en"))
        XCTAssertEqual(target.text, "hello привіт")
        XCTAssertEqual(target.selection, NSRange(location: 12, length: 0))
    }

    func testReplaceWordOnTargetReturnsFalseAndLeavesStateWhenWriteFails() {
        let app = makeApp()
        let target = FakeTextTarget("ghbdsn", caret: 6)
        target.failWrite = true
        XCTAssertFalse(app.replaceWord(on: target, original: "ghbdsn", converted: "привіт",
                                       boundaryToInsert: " ", restoreLangPrefix: "en"))
        XCTAssertEqual(target.text, "ghbdsn")                              // unchanged
        XCTAssertEqual(target.selection, NSRange(location: 6, length: 0))  // caret untouched
    }

    func testReplaceWordOnTargetRefusesActiveSelection() {
        let app = makeApp()
        let target = FakeTextTarget("ghbdsn", selection: NSRange(location: 0, length: 6))
        XCTAssertFalse(app.replaceWord(on: target, original: "ghbdsn", converted: "привіт",
                                       boundaryToInsert: nil, restoreLangPrefix: "en"))
        XCTAssertEqual(target.text, "ghbdsn")
        XCTAssertEqual(target.writeCount, 0)
    }

    func testReplaceWordOnTargetRefusesWhenWordNotFound() {
        let app = makeApp()
        let target = FakeTextTarget("hello", caret: 5)
        XCTAssertFalse(app.replaceWord(on: target, original: "ghbdsn", converted: "привіт",
                                       boundaryToInsert: nil, restoreLangPrefix: "en"))
        XCTAssertEqual(target.writeCount, 0)
    }

    func testCorrectLastWordOnTargetConvertsTrailingWord() {
        let app = makeApp()
        let target = FakeTextTarget("hello ghbdsn ", caret: 13)
        let ok = app.correctLastWord(on: target,
                                     convert: { app.convert($0, from: "en", to: "uk") },
                                     restoreLangPrefix: "en")
        XCTAssertTrue(ok)
        XCTAssertEqual(target.text, "hello привіт ")
        XCTAssertEqual(target.selection, NSRange(location: 13, length: 0))
    }

    func testCorrectLastWordOnTargetNoOpReturnsFalse() {
        let app = makeApp()
        let target = FakeTextTarget("hello", caret: 5)
        XCTAssertFalse(app.correctLastWord(on: target, convert: { $0 }, restoreLangPrefix: "en"))
        XCTAssertEqual(target.text, "hello")
        XCTAssertEqual(target.writeCount, 0)
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

    // MARK: - Key-event routing

    func testConversionDisabledLetsKeystrokesPassThroughUnbuffered() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = LayoutPreferences(defaults: defaults)
        let app = makeApp(preferences: prefs)

        let toggle = try keyEvent(
            keyCode: prefs.toggleHotkey.keyCode,
            flags: CGEventFlags(rawValue: UInt64(prefs.toggleHotkey.modifiers.rawValue)))
        _ = app.testHandleKeyEvent(type: .keyDown, event: toggle)
        XCTAssertFalse(app.testConversionOn)

        let letter = try keyEvent(character: "a")
        let returned = app.testHandleKeyEvent(type: .keyDown, event: letter)?.takeUnretainedValue()
        XCTAssertTrue(returned === letter)
        XCTAssertTrue(app.testWordBuffer.isEmpty)
    }

    func testCommandShortcutPassesThroughWithoutBuffering() throws {
        let app = makeApp()
        app.testWordBuffer = "hel"

        let event = try keyEvent(character: "a", flags: .maskCommand)
        let returned = app.testHandleKeyEvent(type: .keyDown, event: event)?.takeUnretainedValue()

        XCTAssertTrue(returned === event)
        XCTAssertEqual(app.testWordBuffer, "hel")   // shortcut must not edit the word buffer
    }

    func testOptionComboPassesThroughWithoutBuffering() throws {
        let app = makeApp()
        app.testWordBuffer = "hel"

        let event = try keyEvent(character: "s", flags: .maskAlternate)
        let returned = app.testHandleKeyEvent(type: .keyDown, event: event)?.takeUnretainedValue()

        XCTAssertTrue(returned === event)
        XCTAssertEqual(app.testWordBuffer, "hel")
    }

    func testValidEnglishWordIsNotConverted() throws {
        let app = makeApp()

        try type("hello", into: app)
        let space = try keyEvent(character: " ")
        let returned = app.testHandleKeyEvent(type: .keyDown, event: space)?.takeUnretainedValue()

        XCTAssertTrue(returned === space)            // boundary passes through, not swallowed
        XCTAssertEqual(app.testCapturedText(), "")   // nothing replaced
        XCTAssertTrue(app.testWordBuffer.isEmpty)
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

/// In-memory `TextTarget` standing in for a focused AX element, so the AX-write
/// orchestration (`replaceWord`/`correctLastWord`) can be exercised
/// deterministically without a live control.
final class FakeTextTarget: TextTarget {
    private var content: NSString
    private var caret: NSRange
    var failWrite = false
    private(set) var writeCount = 0
    private(set) var selectCount = 0

    init(_ text: String, caret: Int) {
        self.content = text as NSString
        self.caret = NSRange(location: caret, length: 0)
    }

    init(_ text: String, selection: NSRange) {
        self.content = text as NSString
        self.caret = selection
    }

    var axElement: AXUIElement? { nil }   // non-AX target → no precise undo recorded
    var text: String? { content as String }
    var selection: NSRange? { caret }

    func write(_ newText: String) -> Bool {
        guard !failWrite else { return false }
        content = newText as NSString
        writeCount += 1
        return true
    }

    func select(_ range: NSRange) -> Bool {
        caret = range
        selectCount += 1
        return true
    }
}

// MARK: - WordParser

final class WordParserTests: XCTestCase {
    private func scalar(_ string: String) -> UnicodeScalar { string.unicodeScalars.first! }

    func testSplitTrailingMappedStripsTrailingPunctuation() {
        let p = WordParser()
        XCTAssertEqual(p.splitTrailingMapped("привіт").core, "привіт")
        XCTAssertEqual(p.splitTrailingMapped("привіт").trailingCount, 0)

        let one = p.splitTrailingMapped("будь.")
        XCTAssertEqual(one.core, "будь")
        XCTAssertEqual(one.trailingCount, 1)

        let three = p.splitTrailingMapped("test.,;")
        XCTAssertEqual(three.core, "test")
        XCTAssertEqual(three.trailingCount, 3)

        XCTAssertEqual(p.splitTrailingMapped(".,;").core, "")
        XCTAssertEqual(p.splitTrailingMapped("a.b").core, "a.b")   // non-trailing dot is kept
    }

    func testContainsSuspiciousMappedExcludesApostrophe() {
        let p = WordParser()
        XCTAssertFalse(p.containsSuspiciousMapped("ghbdsn"))
        XCTAssertTrue(p.containsSuspiciousMapped("ghbdsn."))
        XCTAssertTrue(p.containsSuspiciousMapped("a,b"))
        XCTAssertTrue(p.containsSuspiciousMapped("[x]"))
        XCTAssertTrue(p.containsSuspiciousMapped("two words"))      // space counts
        XCTAssertFalse(p.containsSuspiciousMapped("it's"))          // apostrophe excluded
    }

    func testIsMappedLatinPunctuation() {
        let p = WordParser()
        for c in "[];',." { XCTAssertTrue(p.isMappedLatinPunctuation(scalar(String(c))), "\(c)") }
        XCTAssertFalse(p.isMappedLatinPunctuation(scalar("/")))
        XCTAssertFalse(p.isMappedLatinPunctuation(scalar("a")))
    }

    func testIsWordInternal() {
        let p = WordParser()
        XCTAssertTrue(p.isWordInternal(scalar("'")))
        XCTAssertTrue(p.isWordInternal(scalar("’")))
        XCTAssertTrue(p.isWordInternal(scalar("-")))
        XCTAssertFalse(p.isWordInternal(scalar("a")))
        XCTAssertFalse(p.isWordInternal(scalar(" ")))
    }

    func testIsBoundary() {
        let p = WordParser()
        XCTAssertTrue(p.isBoundary(scalar(" ")))
        XCTAssertTrue(p.isBoundary(scalar(".")))
        XCTAssertTrue(p.isBoundary(scalar("!")))
        XCTAssertFalse(p.isBoundary(scalar("-")))   // word-internal, not a boundary
        XCTAssertFalse(p.isBoundary(scalar("'")))   // word-internal
        XCTAssertFalse(p.isBoundary(scalar("a")))
    }

    func testLetterClassification() {
        let p = WordParser()
        XCTAssertTrue(p.isLatinLetter(scalar("a")))
        XCTAssertTrue(p.isLatinLetter(scalar("Z")))
        XCTAssertFalse(p.isLatinLetter(scalar("я")))
        XCTAssertFalse(p.isLatinLetter(scalar("1")))

        XCTAssertTrue(p.isCyrillicLetter(scalar("я")))
        XCTAssertTrue(p.isCyrillicLetter(scalar("ї")))
        XCTAssertTrue(p.isCyrillicLetter(scalar("ґ")))
        XCTAssertFalse(p.isCyrillicLetter(scalar("a")))
    }

    func testBufferAppendCompleteAndClear() {
        let p = WordParser()
        XCTAssertNil(p.completeWord())                       // empty buffer → nil
        for sc in "hi".unicodeScalars { p.append(character: sc) }
        XCTAssertEqual(p.buffer, "hi")
        XCTAssertEqual(p.completeWord(), "hi")               // returns and clears
        XCTAssertTrue(p.buffer.isEmpty)
        XCTAssertNil(p.completeWord())
    }

    func testRemoveLastIsSafeOnEmptyBuffer() {
        let p = WordParser()
        p.removeLast()                                       // must not crash
        XCTAssertTrue(p.buffer.isEmpty)
        for sc in "ab".unicodeScalars { p.append(character: sc) }
        p.removeLast()
        XCTAssertEqual(p.buffer, "a")
        p.clear()
        XCTAssertTrue(p.buffer.isEmpty)
    }
}

// MARK: - Hotkey

final class HotkeyTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let hk = Hotkey(keyCode: CGKeyCode(kVK_ANSI_Z),
                        modifiers: [.control, .option, .command],
                        display: "⌃⌥⌘Z")
        let data = try JSONEncoder().encode(hk)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: data)

        XCTAssertEqual(decoded, hk)
        XCTAssertEqual(decoded.keyCode, CGKeyCode(kVK_ANSI_Z))
        XCTAssertEqual(decoded.modifiers, [.control, .option, .command])
        XCTAssertEqual(decoded.display, "⌃⌥⌘Z")
    }

    func testEquatable() {
        let a = Hotkey(keyCode: 1, modifiers: [.command], display: "x")
        let b = Hotkey(keyCode: 1, modifiers: [.command], display: "x")
        let c = Hotkey(keyCode: 2, modifiers: [.command], display: "x")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - LayoutPreferences

final class LayoutPreferencesTests: XCTestCase {
    private func freshDefaults() throws -> (defaults: UserDefaults, name: String) {
        let name = UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testDefaultHotkeysWhenNothingStored() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = LayoutPreferences(defaults: defaults)

        XCTAssertEqual(prefs.toggleHotkey,
                       Hotkey(keyCode: CGKeyCode(kVK_ANSI_0), modifiers: [.control, .option, .command], display: "⌃⌥⌘0"))
        XCTAssertEqual(prefs.convertHotkey,
                       Hotkey(keyCode: CGKeyCode(kVK_Space), modifiers: [.control, .option], display: "⌃⌥Space"))
        XCTAssertEqual(prefs.forceCorrectHotkey,
                       Hotkey(keyCode: CGKeyCode(kVK_ANSI_F), modifiers: [.control, .option, .command], display: "⌃⌥⌘F"))
        XCTAssertEqual(prefs.undoCorrectionHotkey,
                       Hotkey(keyCode: CGKeyCode(kVK_ANSI_Z), modifiers: [.control, .option, .command], display: "⌃⌥⌘Z"))
    }

    func testHotkeyPersistsAndRoundTrips() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = LayoutPreferences(defaults: defaults)

        let custom = Hotkey(keyCode: CGKeyCode(kVK_ANSI_K), modifiers: [.command], display: "⌘K")
        prefs.toggleHotkey = custom

        XCTAssertEqual(prefs.toggleHotkey, custom)
        // A fresh instance over the same store reads back the persisted value.
        XCTAssertEqual(LayoutPreferences(defaults: defaults).toggleHotkey, custom)
    }

    func testLayoutIDsPersist() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = LayoutPreferences(defaults: defaults)

        prefs.primaryID = "com.apple.keylayout.US"
        prefs.secondaryID = "com.apple.keylayout.Ukrainian-PC"

        XCTAssertEqual(prefs.primaryID, "com.apple.keylayout.US")
        XCTAssertEqual(prefs.secondaryID, "com.apple.keylayout.Ukrainian-PC")
        XCTAssertEqual(LayoutPreferences(defaults: defaults).primaryID, "com.apple.keylayout.US")
    }
}
