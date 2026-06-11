import Foundation

/// The string/index math behind the in-place word corrections, separated from
/// the Accessibility get/set so the risky parts — word location, boundary-gap
/// tolerance, caret adjustment, and boundary baking — can be unit-tested with
/// plain strings instead of a live `AXUIElement`.
enum WordReplacementPlanner {

    /// A fully-computed edit: the resulting text, where the caret should land,
    /// the range now occupied by the corrected word, and the surrounding
    /// context (used to re-anchor an undo).
    struct Plan: Equatable {
        let original: String
        let converted: String
        let newText: String
        let newCaret: Int
        let correctedRange: NSRange
        let before: String
        let after: String
    }

    private static let letters = CharacterSet.letters
    private static let wordInternal = Set("'’-".unicodeScalars)

    private static func isLetter(_ s: UnicodeScalar) -> Bool { letters.contains(s) }
    private static func isWordChar(_ s: UnicodeScalar) -> Bool { letters.contains(s) || wordInternal.contains(s) }

    /// Plan replacing a *known* `original` word that sits immediately before the
    /// caret with `converted`, optionally baking a swallowed boundary after it.
    /// Returns nil when the word can't be confidently located (caller falls back
    /// to synthetic keystrokes).
    static func planReplacement(fullText ns: NSString,
                                caret: Int,
                                original: String,
                                converted: String,
                                boundaryToInsert: UnicodeScalar?,
                                contextRadius: Int) -> Plan? {
        guard !original.isEmpty else { return nil }
        let origLen = (original as NSString).length
        guard caret >= origLen, caret <= ns.length else { return nil }

        // Most recent occurrence of `original` ending at — or within a short
        // boundary gap of — the caret.
        let found = ns.range(of: original, options: .backwards,
                             range: NSRange(location: 0, length: caret))
        guard found.location != NSNotFound else { return nil }
        let gap = caret - (found.location + found.length)
        guard gap >= 0, gap <= 2 else { return nil }
        if gap > 0 {
            // Anything between the word and the caret must be a boundary, never
            // letters we'd silently corrupt.
            let between = ns.substring(with: NSRange(location: found.location + found.length, length: gap))
            guard between.unicodeScalars.allSatisfy({ !isLetter($0) }) else { return nil }
        }
        return finish(ns: ns, caret: caret, wordRange: found, original: original,
                      converted: converted, boundaryToInsert: boundaryToInsert,
                      contextRadius: contextRadius)
    }

    /// Plan converting the last word (letters + word-internal chars) at or
    /// before the caret, computing the original from the text itself. Used by
    /// force-correct when there is no known original string. `convert` performs
    /// the layout conversion; the plan is nil when conversion is a no-op.
    static func planLastWord(fullText ns: NSString,
                             caret: Int,
                             convert: (String) -> String,
                             contextRadius: Int) -> Plan? {
        guard caret > 0, caret <= ns.length else { return nil }

        var end = caret
        while end > 0, !isWordChar(scalar(ns, end - 1)) { end -= 1 }   // skip trailing boundaries
        guard end > 0 else { return nil }
        var start = end
        while start > 0, isWordChar(scalar(ns, start - 1)) { start -= 1 }
        guard start < end else { return nil }

        let wordRange = NSRange(location: start, length: end - start)
        let original = ns.substring(with: wordRange)
        let converted = convert(original)
        guard converted != original else { return nil }
        return finish(ns: ns, caret: caret, wordRange: wordRange, original: original,
                      converted: converted, boundaryToInsert: nil,
                      contextRadius: contextRadius)
    }

    private static func finish(ns: NSString,
                               caret: Int,
                               wordRange: NSRange,
                               original: String,
                               converted: String,
                               boundaryToInsert: UnicodeScalar?,
                               contextRadius: Int) -> Plan {
        var replacement = converted
        if let boundary = boundaryToInsert { replacement.unicodeScalars.append(boundary) }
        let replacementLen = (replacement as NSString).length
        let convertedLen = (converted as NSString).length
        let newText = ns.replacingCharacters(in: wordRange, with: replacement) as NSString

        let newCaret = max(0, adjustedCaret(caret, afterReplacing: wordRange, withLength: replacementLen))
        // Undo targets the corrected word only (not any baked boundary); anchor
        // its context against the resulting text so relocation stays accurate.
        let correctedRange = NSRange(location: wordRange.location, length: convertedLen)
        let (before, after) = context(around: correctedRange, in: newText, radius: contextRadius)
        return Plan(original: original, converted: converted,
                    newText: newText as String, newCaret: newCaret,
                    correctedRange: correctedRange, before: before, after: after)
    }

    private static func scalar(_ ns: NSString, _ index: Int) -> UnicodeScalar {
        let s = ns.substring(with: NSRange(location: index, length: 1))
        return s.unicodeScalars.first ?? UnicodeScalar(0)
    }

    /// Where the caret should land after `replacedRange` is swapped for text of
    /// length `newLength`.
    static func adjustedCaret(_ caret: Int, afterReplacing replacedRange: NSRange, withLength newLength: Int) -> Int {
        let delta = newLength - replacedRange.length
        let afterIndex = replacedRange.location + replacedRange.length
        if caret >= afterIndex {
            return caret + delta
        } else if caret >= replacedRange.location && caret <= afterIndex {
            let insideOffset = caret - replacedRange.location
            return replacedRange.location + min(insideOffset, newLength)
        } else {
            return caret
        }
    }

    /// Surrounding text (±`radius`) used to re-anchor a range during undo.
    static func context(around range: NSRange, in ns: NSString, radius: Int) -> (before: String, after: String) {
        let beforeStart = max(0, range.location - radius)
        let before = ns.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart))
        let afterStart = range.location + range.length
        let afterLen = min(radius, max(0, ns.length - afterStart))
        let after = ns.substring(with: NSRange(location: afterStart, length: afterLen))
        return (before, after)
    }
}
