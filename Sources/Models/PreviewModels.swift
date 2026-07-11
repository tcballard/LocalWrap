import Foundation

enum PreviewLoadStatus: String, Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

struct PreviewState: Equatable, Sendable {
    var isVisible = false
    var status: PreviewLoadStatus = .idle
    var currentURL: URL?
    var errorMessage: String?
    var reloadToken = 0

    mutating func open(_ url: URL) {
        isVisible = true
        status = .loading
        currentURL = url
        errorMessage = nil
    }

    mutating func close() {
        isVisible = false
        status = .idle
        currentURL = nil
        errorMessage = nil
        reloadToken = 0
    }

    mutating func reload() {
        guard isVisible else { return }
        status = .loading
        errorMessage = nil
        reloadToken += 1
    }
}
