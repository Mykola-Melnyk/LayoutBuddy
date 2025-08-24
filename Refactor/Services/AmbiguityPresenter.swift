import Foundation

@MainActor
protocol AmbiguityPresenter {
  func present(options: [Candidate], original: String) async -> Candidate?
}
