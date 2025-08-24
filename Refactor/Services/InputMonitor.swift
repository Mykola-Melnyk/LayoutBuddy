import Cocoa

struct KeyEvent {
  let type: CGEventType
  let cgEvent: CGEvent
}

protocol InputMonitor: AnyObject {
  func start(onEvent: @escaping (KeyEvent) -> Void)
  func stop()
}
