import ApplicationServices

final class AXPermissions: Permissions {
    var axReady: Bool { AXIsProcessTrusted() }

    func requestIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}
