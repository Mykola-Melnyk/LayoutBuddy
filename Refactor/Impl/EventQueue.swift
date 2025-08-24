import Foundation
import ApplicationServices

final class EventQueue {
  private var buffer: [CGEvent] = []
  private(set) var isSynthesizing = false

  func enqueue(_ e: CGEvent) {
    if isSynthesizing { buffer.append(e) } else { dispatch(e) }
  }

  func beginSynth() { isSynthesizing = true }

  func endSynth() {
    isSynthesizing = false
    for e in buffer { dispatch(e) }
    buffer.removeAll()
  }

  private func dispatch(_ e: CGEvent) {
    e.post(tap: .cghidEventTap)
  }
}
