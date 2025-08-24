import ApplicationServices
import AppKit


@MainActor
protocol ReplacementPerformer {
    func replace(in element: AXUIElement, range: TextRange, with text: String) async throws
    func beginSynthesis()
    func endSynthesis()
    func synthesizeDeletion(count: Int)
    func synthesizeInsertion(_ text: String)
    func synthesizeDeleteWordLeft()
}

enum ReplacementError: Error {
    case unavailableAX(String)
    case setFailed
}
