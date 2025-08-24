#if canImport(ApplicationServices)
import Testing
@testable import LayoutBuddy
import Foundation

final class FakeAXClient: AXClient {
    var text = "the "
    var selection = NSRange(location: 4, length: 0)
    var didReplace = false

    func focusedTextElement() -> AXTextElement? { AXTextElement() }
    func readValue(_ el: AXTextElement) -> String? { text }
    func readSelectedRange(_ el: AXTextElement) -> NSRange? { selection }
    func replace(_ el: AXTextElement, in range: NSRange, with string: String) -> Bool {
        let ns = text as NSString
        text = ns.replacingCharacters(in: range, with: string)
        selection = NSRange(location: range.location + (string as NSString).length, length: 0)
        didReplace = true
        return true
    }
}

@MainActor
struct AXScenarioTests {
    @Test func testAXWordReplacement_DI() async throws {
        let app = AppCoordinator()
        let ax = FakeAXClient()
        app.enableAXForTests(ax)

        app.simulateWordBoundaryAfterTyping("the")
        app.testApplyMostRecentAmbiguitySynchronously()

        #expect(ax.didReplace)
        #expect(ax.text == "еру ")
    }
}
#endif
