import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// Tracks and requests the two privacy permissions LayoutBuddy needs to work:
///
/// - **Accessibility** — to read the word you just typed and replace it, and to
///   post the synthetic keystrokes used by the fallback path.
/// - **Input Monitoring** — to observe the global keyboard through the event tap
///   so it knows *when* to convert.
///
/// Both are granted at runtime via macOS TCC; neither is an entitlement.
final class PermissionsManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false

    /// True once both permissions are granted — i.e. the app can actually function.
    var allGranted: Bool { accessibilityGranted && inputMonitoringGranted }

    init() {
        refresh()
    }

    /// Re-reads the current grant state. Cheap; safe to call on a poll timer
    /// because the user grants these in System Settings, out of our process.
    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    // MARK: - Requests (show the system prompt the first time)

    /// Triggers the Accessibility prompt. After the first call macOS only opens
    /// Settings, so callers also offer `openAccessibilitySettings()`.
    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    // MARK: - Deep links into System Settings

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
