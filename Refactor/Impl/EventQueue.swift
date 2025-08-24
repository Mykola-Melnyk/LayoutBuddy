import ApplicationServices

@MainActor
final class EventQueue {
    private var buffer: [CGEvent] = []
    private(set) var isSynthesizing = false

    func beginSynth() { isSynthesizing = true }

    func endSynth() {
        isSynthesizing = false
        // Flush buffered events in order
        for ev in buffer { dispatch(ev) }
        buffer.removeAll(keepingCapacity: false)
    }

    func enqueue(_ event: CGEvent) {
        if isSynthesizing {
            buffer.append(event)
        } else {
            dispatch(event)
        }
    }

    private func dispatch(_ event: CGEvent) {
        // Post at HID tap so the system processes the synthesized keystrokes
        event.post(tap: .cghidEventTap)
    }
}

