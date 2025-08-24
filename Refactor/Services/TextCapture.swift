import AppKit

enum TextCaptureError: Error {
  case noFocusedElement
  case notEditable
  case noSelection
  case noWord
  case cannotReadText
}

enum CaretAnchor {
  case currentCaret
}

@MainActor
protocol TextCapture {
  func captureWord(at anchor: CaretAnchor) async throws -> TextContext
}
