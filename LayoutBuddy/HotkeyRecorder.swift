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
        nsView.stringValue = hotkey.display
    }

    final class HotkeyField: NSTextField {
        var onChange: (Hotkey) -> Void = { _ in }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isEditable = false
            isBezeled = true
            alignment = .center
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            stringValue = ""
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
            let keyString = chars == " " ? "Space" : chars.uppercased()
            let display = Self.format(mods: mods) + keyString
            stringValue = display
            onChange(Hotkey(keyCode: event.keyCode, modifiers: mods, display: display))
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
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
