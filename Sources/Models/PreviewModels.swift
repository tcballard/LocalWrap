import Foundation

enum PreviewLoadStatus: String, Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

enum PreviewViewportPreset: String, CaseIterable, Identifiable, Equatable, Sendable {
    case fit
    case compact
    case tablet
    case desktop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: "Responsive"
        case .compact: "Phone"
        case .tablet: "Tablet"
        case .desktop: "Desktop"
        }
    }

    var width: CGFloat? {
        switch self {
        case .fit: nil
        case .compact: 390
        case .tablet: 768
        case .desktop: 1_280
        }
    }

    var accessibilityValue: String {
        guard let width else { return "Fit to available width" }
        return "\(Int(width)) points wide"
    }
}

struct PreviewWebSnapshot: Equatable, Sendable {
    var currentURL: URL?
    var pageTitle: String?
    var canGoBack: Bool
    var canGoForward: Bool
    var estimatedProgress: Double
    var isLoading: Bool

    init(
        currentURL: URL? = nil,
        pageTitle: String? = nil,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        estimatedProgress: Double = 0,
        isLoading: Bool = false
    ) {
        self.currentURL = currentURL
        self.pageTitle = pageTitle
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.estimatedProgress = estimatedProgress
        self.isLoading = isLoading
    }
}

/// The only Live Preview state that can change Needs Attention. Navigation
/// tokens, progress, titles, and history controls are deliberately excluded.
struct PreviewFailureEvidence: Equatable, Sendable {
    let currentURL: String?
    let message: String?
}

struct PreviewState: Equatable, Sendable {
    var isVisible = false
    var status: PreviewLoadStatus = .idle
    var currentURL: URL?
    var pageTitle: String?
    var errorMessage: String?
    var canGoBack = false
    var canGoForward = false
    var estimatedProgress = 0.0
    var hasLoadedContent = false
    var backToken = 0
    var forwardToken = 0
    var reloadToken = 0
    var stopToken = 0

    var attentionFailureEvidence: PreviewFailureEvidence? {
        guard status == .failed else { return nil }
        return PreviewFailureEvidence(
            currentURL: currentURL?.absoluteString,
            message: errorMessage
        )
    }

    mutating func open(_ url: URL) {
        self = PreviewState()
        isVisible = true
        currentURL = url
        markLoading()
    }

    mutating func close() {
        self = PreviewState()
    }

    mutating func goBack() {
        guard isVisible, canGoBack else { return }
        backToken += 1
    }

    mutating func goForward() {
        guard isVisible, canGoForward else { return }
        forwardToken += 1
    }

    mutating func reload() {
        guard isVisible else { return }
        reloadToken += 1
    }

    mutating func stopLoading() {
        guard isVisible, status == .loading else { return }
        stopToken += 1
    }

    mutating func apply(_ snapshot: PreviewWebSnapshot) {
        if let currentURL = snapshot.currentURL {
            self.currentURL = currentURL
        }
        pageTitle = snapshot.pageTitle
        canGoBack = snapshot.canGoBack
        canGoForward = snapshot.canGoForward
        estimatedProgress = min(max(snapshot.estimatedProgress, 0), 1)
        if snapshot.isLoading {
            markLoading(resetProgress: false)
        }
    }

    mutating func markLoading() {
        markLoading(resetProgress: true)
    }

    mutating func markLoaded() {
        guard isVisible else { return }
        status = .ready
        estimatedProgress = 1
        hasLoadedContent = true
        errorMessage = nil
    }

    mutating func markFailed(_ message: String) {
        guard isVisible else { return }
        status = .failed
        errorMessage = message
    }

    private mutating func markLoading(resetProgress: Bool) {
        guard isVisible else { return }
        status = .loading
        if resetProgress {
            estimatedProgress = 0
        }
        errorMessage = nil
    }
}
