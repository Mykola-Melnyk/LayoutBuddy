import Foundation

/// Example layout mapper; replace with your real mapping logic.
struct LayoutMapper: Resolver {
  func resolve(_ word: String) -> Resolution {
    guard !word.isEmpty else { return .noop }
    // Example: if mapping is deterministic, return .unambiguous
    let mapped = mapQwertyToUkr(word)
    return mapped == word ? .noop : .unambiguous(mapped)
  }

  private func mapQwertyToUkr(_ s: String) -> String {
    // Minimal demo map (you likely already have a full map elsewhere):
    let map: [Character: Character] = [
      "q":"й","w":"ц","e":"у","r":"к","t":"е","y":"н","u":"г","i":"ш","o":"щ","p":"з",
      "a":"ф","s":"і","d":"в","f":"а","g":"п","h":"р","j":"о","k":"л","l":"д",
      "z":"я","x":"ч","c":"с","v":"м","b":"и","n":"т","m":"ь"
    ]
    return String(s.map { map[$0] ?? $0 })
  }
}
