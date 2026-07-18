import Foundation

enum PreviewNavigationDecision: Equatable, Sendable {
    case allow
    case openExternal(URL)
    case cancel
}

struct PreviewNavigationContext: Equatable, Sendable {
    let url: URL?
    let isMainFrame: Bool
    let isUserActivated: Bool

    init(url: URL?, isMainFrame: Bool, isUserActivated: Bool) {
        self.url = url
        self.isMainFrame = isMainFrame
        self.isUserActivated = isUserActivated
    }

    static func resolvingWebKitFrames(
        url: URL?,
        targetFrameIsMain: Bool?,
        sourceFrameIsMain: Bool,
        isUserActivated: Bool
    ) -> PreviewNavigationContext {
        PreviewNavigationContext(
            url: url,
            isMainFrame: targetFrameIsMain ?? sourceFrameIsMain,
            isUserActivated: isUserActivated
        )
    }
}

struct PreviewNavigationPolicy: Sendable {
    let localURLValidator: LocalURLValidator

    init(localURLValidator: LocalURLValidator = LocalURLValidator()) {
        self.localURLValidator = localURLValidator
    }

    func decision(for url: URL?) -> PreviewNavigationDecision {
        decision(for: PreviewNavigationContext(
            url: url,
            isMainFrame: true,
            isUserActivated: true
        ))
    }

    func decision(for context: PreviewNavigationContext) -> PreviewNavigationDecision {
        guard let url = context.url else { return .cancel }
        if localURLValidator.validate(url.absoluteString) {
            return .allow
        }
        let host = url.host?
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let host, LocalURLValidator.allowedHosts.contains(host) {
            return .cancel
        }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .cancel
        }
        guard context.isMainFrame, context.isUserActivated else { return .cancel }
        return .openExternal(url)
    }

    func allowsResponse(
        url: URL?,
        canShowMIMEType: Bool,
        contentDisposition: String?
    ) -> Bool {
        guard decision(for: url) == .allow, canShowMIMEType else { return false }
        return contentDisposition?.lowercased().contains("attachment") != true
    }
}
