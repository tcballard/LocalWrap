import Foundation

struct HealthCheckResolution: Equatable, Sendable {
    let url: URL?
    let error: String?
    var isValid: Bool { url != nil && error == nil }
}

struct HealthCheckResolver: Sendable {
    let urlValidator: LocalURLValidator

    init(urlValidator: LocalURLValidator = LocalURLValidator()) {
        self.urlValidator = urlValidator
    }

    func resolve(projectURL: String, healthCheck: HealthCheck?) -> HealthCheckResolution {
        if let healthCheck {
            let path = healthCheck.path?.trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitURL = healthCheck.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            if (path?.isEmpty == false) == (explicitURL?.isEmpty == false) {
                return invalid("Health check must contain either a path or a URL.")
            }
            if let explicitURL, !explicitURL.isEmpty {
                guard let url = urlValidator.url(from: explicitURL) else {
                    return invalid("Health check URL must be local http(s) on an allowed port.")
                }
                return HealthCheckResolution(url: url, error: nil)
            }
            guard let path, path.hasPrefix("/") else {
                return invalid("Health check path must start with /.")
            }
            guard var components = URLComponents(string: projectURL),
                  urlValidator.validate(projectURL) else {
                return invalid("Project URL is not a valid local URL.")
            }
            components.path = path
            components.query = nil
            components.fragment = nil
            guard let url = components.url, urlValidator.validate(url.absoluteString) else {
                return invalid("Health check could not be resolved to a local URL.")
            }
            return HealthCheckResolution(url: url, error: nil)
        }
        guard let url = urlValidator.url(from: projectURL) else {
            return invalid("Project URL is not a valid local URL.")
        }
        return HealthCheckResolution(url: url, error: nil)
    }

    func resolve(_ project: Project) -> HealthCheckResolution {
        resolve(projectURL: project.url, healthCheck: project.healthCheck)
    }

    private func invalid(_ message: String) -> HealthCheckResolution {
        HealthCheckResolution(url: nil, error: message)
    }
}
