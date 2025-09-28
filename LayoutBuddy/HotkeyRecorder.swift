import SwiftUI

struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: Hotkey

    func makeNSView(context: Context) -> HotkeyField {
        let field = HotkeyField()
        field.stringValue = hotkey.display
        field.onChange = { hk in
            self.hotkey = hk
        }
        return field
    }

    func updateNSView(_ nsView: HotkeyField, context: Context) {
        let display = hotkey.display
        if nsView.stringValue != display {
            nsView.stringValue = display
        }
    }

    final class HotkeyField: NSTextField {
        var onChange: (Hotkey) -> Void = { _ in }
        private var recording = false
        private var originalDisplay = ""

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
            isEditable = false
            isBezeled = true
            alignment = .center
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            stringValue = ""
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            originalDisplay = stringValue
            recording = true
            stringValue = "Recording shortcut…"
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            if recording {
                recording = false
                stringValue = originalDisplay
            }
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
            let keyString = chars == " " ? "Space" : chars.uppercased()
            let display = Self.format(mods: mods) + keyString
            stringValue = display
            recording = false
            window?.makeFirstResponder(nil)
            onChange(Hotkey(keyCode: event.keyCode, modifiers: mods, display: display))
        }

        private static func format(mods: NSEvent.ModifierFlags) -> String {
            var s = ""
            if mods.contains(.control) { s += "⌃" }
            if mods.contains(.option) { s += "⌥" }
            if mods.contains(.shift) { s += "⇧" }
            if mods.contains(.command) { s += "⌘" }
            return s
        }
    }
}
