import ApplicationServices

@MainActor
final class EventSynthesizer {
  private let queue = EventQueue()

  func begin() { queue.beginSynth() }
  func end() { queue.endSynth() }

  func backspace(times: Int) {
    guard times > 0 else { return }
    for _ in 0..<times {
      if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x33, keyDown: true),
         let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x33, keyDown: false) {
        queue.enqueue(down)
        queue.enqueue(up)
      }
    }
  }

  func typeString(_ s: String) {
    for scalar in s.unicodeScalars {
      var ch = UniChar(scalar.value)
      guard let evDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let evUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
      else { continue }
      evDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
      evUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
      queue.enqueue(evDown)
      queue.enqueue(evUp)
    }
  }
}
