import Cocoa
import Carbon

/// Source of keyboard input-source data and switching. Abstracted so the
/// manager's caching and the layout-selection logic can be unit-tested against
/// a fake list instead of the live Text Input Source (TIS) APIs.
protocol InputSourceProviding: AnyObject {
    func selectableLayouts() -> [KeyboardLayoutManager.InputSourceInfo]
    func currentInputSourceID() -> String
    func selectInputSource(id: String)
}

/// Live `InputSourceProviding` backed by the Carbon Text Input Source APIs.
/// Single home for the TIS marshalling.
final class TISInputSourceProvider: InputSourceProviding {
    func selectableLayouts() -> [KeyboardLayoutManager.InputSourceInfo] {
        let query: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as CFString,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        guard let list = TISCreateInputSourceList(query as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }

        let infos = list.compactMap { src -> KeyboardLayoutManager.InputSourceInfo? in
            let id = (tisProperty(src, kTISPropertyInputSourceID) as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let name = (tisProperty(src, kTISPropertyLocalizedName) as? String) ?? id
            let langs = (tisProperty(src, kTISPropertyInputSourceLanguages) as? [String]) ?? []
            return KeyboardLayoutManager.InputSourceInfo(id: id, name: name, languages: langs)
        }
        return infos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func currentInputSourceID() -> String {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
        return (tisProperty(cur, kTISPropertyInputSourceID) as? String) ?? ""
    }

    func selectInputSource(id: String) {
        let query: [CFString: Any] = [
            kTISPropertyInputSourceID: id,
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as CFString,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        if let list = TISCreateInputSourceList(query as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource],
           let target = list.first {
            TISEnableInputSource(target)
            TISSelectInputSource(target)
        }
    }

    private func tisProperty(_ src: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }
}
