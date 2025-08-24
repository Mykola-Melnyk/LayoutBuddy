import AppKit

@MainActor
final class RefactorCoordinator {
    private let input: InputMonitor
    private let capture: TextCapture
    private let resolver: Resolver
    private let replace: ReplacementPerformer
    private let ui: AmbiguityPresenter
    private let perms: Permissions

    private(set) var mode: AppMode = .idle
    private var lastContext: TextContext?

    init(
        input: InputMonitor,
        capture: TextCapture,
        resolver: Resolver,
        replace: ReplacementPerformer,
        ui: AmbiguityPresenter,
        perms: Permissions
    ) {
        self.input = input
        self.capture = capture
        self.resolver = resolver
        self.replace = replace
        self.ui = ui
        self.perms = perms
    }

    func start() {
        input.start { [weak self] ev in
            self?.handleKeyEvent(ev)
        }
    }

    private func isWordBoundary(_ ev: KeyEvent) -> Bool {
        guard ev.type == .keyDown else { return false }

        // Always treat Return and Tab as boundaries by keycode
        let code = ev.cgEvent.getIntegerValueField(.keyboardEventKeycode)
        if code == 0x24 || code == 0x30 { return true } // Return, Tab

        // Try to classify by produced Unicode character (layout-aware)
        var buf = [UniChar](repeating: 0, count: 4)
        var len: Int = 0
        ev.cgEvent.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        if len > 0 {
            let scalar = UnicodeScalar(buf[0])
            if let scalar {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
                if CharacterSet.punctuationCharacters.contains(scalar) { return true }
            }
        }

        // Fallback: treat Space by keycode as boundary
        // Space keycode is 0x31 on macOS key layouts
        return code == 0x31
    }

    private var inFlight = false

    private func handleKeyEvent(_ event: KeyEvent) {
        if !isWordBoundary(event) { return }
        if inFlight { return }           // throttle bursts
        inFlight = true
        Task { @MainActor [weak self] in
            defer { self?.inFlight = false }
            await self?.convertFocusedWord()
        }
    }
    
    func stop() {
        input.stop()
    }

    func convertFocusedWord() async {
        guard perms.axReady else {
            fallbackConvertCurrentWord()
            return
        }
        do {
            let ctx = try await capture.captureWord(at: .currentCaret)
            lastContext = ctx
            mode = .capturingWord(ctx)
            switch resolver.resolve(ctx.word) {
            case .noop:
                mode = .idle
            case .unambiguous(let converted):
                mode = .replacingText(ctx.range)
                try await replace.replace(in: ctx.element, range: ctx.range, with: converted)
                mode = .idle
            case .ambiguous(let options):
                mode = .resolvingAmbiguity(original: ctx.word, options: options)
                if let picked = await ui.present(options: options, original: ctx.word) {
                    mode = .replacingText(ctx.range)
                    try await replace.replace(in: ctx.element, range: ctx.range, with: picked.text)
                }
                mode = .idle
            }
        } catch {
            fallbackConvertCurrentWord()
        }
    }

    private func fallbackConvertCurrentWord() {
        mode = .synthesizing
        replace.beginSynthesis()
        defer {
            replace.endSynthesis()
            mode = .idle
        }
        guard let ctx = lastContext else { return }
        let word = ctx.word
        let resolution = resolver.resolve(word)
        switch resolution {
        case .noop:
            return
        case .unambiguous(let converted):
            replace.synthesizeDeletion(count: word.count)
            replace.synthesizeInsertion(converted)
        case .ambiguous(let options):
            if let first = options.first {
                replace.synthesizeDeletion(count: word.count)
                replace.synthesizeInsertion(first.text)
            }
        }
    }
}
