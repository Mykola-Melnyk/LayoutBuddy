import AppKit
import ApplicationServices

final class EventTapInputMonitor: InputMonitor {
    private var tap: CFMachPort?
    private var onEvent: ((KeyEvent) -> Void)?

    private let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

    func start(onEvent: @escaping (KeyEvent) -> Void) {
        self.onEvent = onEvent

        // Use the session event tap, which is sufficient for keyDown monitoring
        // and typically does not require the lower-level HID privileges.
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<EventTapInputMonitor>
                    .fromOpaque(userInfo).takeUnretainedValue()

                // forward every keyDown to the coordinator
                monitor.onEvent?(KeyEvent(type: type, cgEvent: event))

                // never swallow keystrokes in auto mode
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap else { return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("LB: tap installed")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        onEvent = nil
    }
}
