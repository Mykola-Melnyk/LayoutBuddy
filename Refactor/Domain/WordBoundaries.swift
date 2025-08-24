import Foundation

struct WordBoundaries {
  /// Returns the UTF-16 range for the word that contains `caretUTF16` in `fullText`.
  func currentWordRangeUTF16(in fullText: String, caretUTF16: Int) -> TextRange? {
    // Simple word regex you can refine:
    // Treat word chars as letters+digits+underscore; extend to apostrophes if needed.
    let scalars = Array(fullText.utf16)
    guard caretUTF16 >= 0, caretUTF16 <= scalars.count else { return nil }

    var start = caretUTF16
    var end = caretUTF16

    while start > 0, isWordChar(scalars[start - 1]) { start -= 1 }
    while end < scalars.count, isWordChar(scalars[end]) { end += 1 }

    guard end > start else { return nil }
    return TextRange(location: start, length: end - start)
  }

  private func isWordChar(_ u: UniChar) -> Bool {
    // ASCII letters/digits/_ fast path; expand as you like.
    if (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u) || u == 95 { return true }
    // Add Cyrillic letters (U+0400–U+04FF) as word chars:
    if (0x0400...0x04FF).contains(Int(u)) { return true }
    return false
  }
}
