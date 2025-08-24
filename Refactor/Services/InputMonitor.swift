import Cocoa

protocol InputMonitor: AnyObject {
  func start(onEvent: @escaping (KeyEvent) -> Void)
  func stop()
}
