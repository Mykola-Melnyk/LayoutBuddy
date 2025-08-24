import AppKit

struct TextRange: Equatable {
  var location: Int // UTF-16 location (AX indexing)
  var length: Int
}

struct TextContext: Equatable {
  let element: AXUIElement
  let fullText: String
  let range: TextRange
  let word: String
  let caretUTF16: Int
}

struct Candidate: Equatable {
  let text: String
}

enum Resolution {
  case noop
  case unambiguous(String)
  case ambiguous([Candidate])
}
