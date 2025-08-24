import AppKit

struct KeyEvent {
    let type: CGEventType
    let cgEvent: CGEvent
}

final class EventTapInputMonitor: InputMonitor {
    private var tap: CFMachPort?
    private var onEvent: ((KeyEvent) -> Void)?

    // keyDown + flagsChanged
    private let mask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

    func start(onEvent: @escaping (KeyEvent) -> Void) {
        self.onEvent = onEvent

        tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<EventTapInputMonitor>
                    .fromOpaque(userInfo).takeUnretainedValue()

                if monitor.isHotkey(event: event) {
                    monitor.onEvent?(KeyEvent(type: type, cgEvent: event))
                    return nil // swallow trigger if you prefer
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap else { return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        onEvent = nil
    }

    // Change this to your preferred hotkey: ⌃⌥⌘Space
    private func isHotkey(event: CGEvent) -> Bool {
        let flags = event.flags
        let wantMods = [CGEventFlags.maskControl, .maskAlternate, .maskCommand]
            .allSatisfy { flags.contains($0) }
        let isSpace = event.getIntegerValueField(.keyboardEventKeycode) == 0x31
        return wantMods && isSpace
    }
}
