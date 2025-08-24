import Cocoa

struct Hotkey: Codable, Equatable {
    var keyCode: CGKeyCode
    var modifiers: NSEvent.ModifierFlags
    var display: String

    init(keyCode: CGKeyCode, modifiers: NSEvent.ModifierFlags, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case display
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(UInt16(keyCode), forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
        try container.encode(display, forKey: .display)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = CGKeyCode(try container.decode(UInt16.self, forKey: .keyCode))
        let raw = try container.decode(UInt.self, forKey: .modifiers)
        modifiers = NSEvent.ModifierFlags(rawValue: raw)
        display = try container.decode(String.self, forKey: .display)
    }
}
