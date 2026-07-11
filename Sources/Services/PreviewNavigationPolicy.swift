import Foundation

enum PreviewNavigationDecision: Equatable, Sendable {
    case allow
    case openExternal(URL)
    case cancel
}

struct PreviewNavigationPolicy: Sendable {
    let localURLValidator: LocalURLValidator

    init(localURLValidator: LocalURLValidator = LocalURLValidator()) {
        self.localURLValidator = localURLValidator
    }

    func decision(for url: URL?) -> PreviewNavigationDecision {
        guard let url else { return .cancel }
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
