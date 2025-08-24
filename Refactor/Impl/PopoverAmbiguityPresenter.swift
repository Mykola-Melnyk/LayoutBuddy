import AppKit

@MainActor
final class PopoverAmbiguityPresenter: AmbiguityPresenter {
    func present(options: [Candidate], original: String) async -> Candidate? {
        // For now, automatically choose the first candidate. Replace with real UI later.
        return options.first
    }
}
