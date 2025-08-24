import Foundation
enum AppMode: Equatable {
  case idle
  case capturingWord(TextContext)
  case resolvingAmbiguity(original: String, options: [Candidate])
  case replacingText(TextRange)
  case synthesizing
}
