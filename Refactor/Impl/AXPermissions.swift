import ApplicationServices

struct AXPermissions: Permissions {
    var axReady: Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
    }
}
