import AppKit

@MainActor
final class AppCoordinator {
    private let input: InputMonitor
    private let capture: TextCapture
    private let resolver: Resolver
    private let replace: ReplacementPerformer
    private let ui: AmbiguityPresenter
    private let perms: Permissions

    private(set) var mode: AppMode = .idle

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
        input.start { [weak self] event in
            guard let self else { return }
            self.handleKeyEvent(event)
        }
    }
    
    func stop()  { input.stop() }

    private func handleKeyEvent(_ event: KeyEvent) {
        // Here you would inspect event to determine if the hotkey was pressed
        // and then trigger conversion. For demo purposes, we call convert on any event.
        Task { @MainActor in
            await self.convertFocusedWord()
        }
    }

    func convertFocusedWord() async {
        guard perms.axReady else {
            fallbackConvertCurrentWord()
            return
        }
        do {
            let ctx = try await capture.captureWord(at: .currentCaret)
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

    private func convertFocusedWord() {
        guard perms.axReady else {
            fallbackConvertCurrentWord()
            return
        }

        mode = .capturing
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.mode = .idle }

            do {
                let ctx = try await capture.captureWord(at: .currentCaret) // TextContext(fullText, range)
                lastContext = ctx

                switch resolver.resolve(ctx.word) {
                case .noop:
                    return
                case .unambiguous(let text):
                    try await replace.replace(in: ctx.element, range: ctx.range, with: text)

                case .ambiguous(let options):
                    if let chosen = await ui.present(options: options, original: ctx.word) {
                        try await replace.replace(in: ctx.element, range: ctx.range, with: chosen.text)
                    }
                }
            } catch {
                // AX path failed → fallback
                fallbackConvertCurrentWord()
            }
        }
    }

    private func fallbackConvertCurrentWord() {
        mode = .synthesizing
        replace.beginSynthesis()
        defer { replace.endSynthesis(); mode = .idle }

        // naive but robust:
        replace.synthesizeDeleteWordLeft()

        // if you have the last captured context and mapping, do it here.
        // For now, just map the last token via resolver if available:
        let toInsert: String = {
            if let last = lastContext {
                switch resolver.resolve(last.word) {
                case .unambiguous(let t): return t
                case .ambiguous(let opts): return opts.first?.text ?? last.word
                case .noop: return last.word
                }
            } else {
                return "" // nothing safe to insert
            }
        }()

        if !toInsert.isEmpty {
            replace.synthesizeInsertion(toInsert)
        }
    }

}
