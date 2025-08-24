import Cocoa
import ApplicationServices

struct KeyEvent {
    let type: CGEventType
    let cgEvent: CGEvent
}

final class EventTapInputMonitor: InputMonitor {
    private var tap: CFMachPort?
    private var onEvent: ((KeyEvent) -> Void)?

    // Set the event mask to monitor keyDown and flagsChanged events
    private let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

    func start(onEvent: @escaping (KeyEvent) -> Void) {
        self.onEvent = onEvent
        // Create the event tap
        tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                place: .headInsertEventTap,
                                options: .defaultTap,
                                eventsOfInterest: mask,
                                callback: { proxy, type, event, userInfo in
            guard let userInfo = userInfo else {
                return Unmanaged.passRetained(event)
            }
            let monitor = Unmanaged<EventTapInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // Check if the event matches the configured hotkey
            if monitor.isHotkey(event: event) {
                // Fire callback and optionally swallow event
                monitor.onEvent?(KeyEvent(type: type, cgEvent: event))
                return nil
            }
            return Unmanaged.passRetained(event)
        },
                                userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        
        guard let tap else { return }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        onEvent = nil
    }

    // Determine if the event corresponds to the chosen hotkey (Control+Option+Command+Space)
    private func isHotkey(event: CGEvent) -> Bool {
        let flags = event.flags
        // Evaluate combination of Control, Option, and Command
        let modifiersSatisfied = flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
        // Key code 0x31 represents the Spacebar
        let isSpacebar = event.getIntegerValueField(.keyboardEventKeycode) == 0x31
        return modifiersSatisfied && isSpacebar
    }
}
