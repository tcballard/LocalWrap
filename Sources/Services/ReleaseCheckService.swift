import Foundation

enum ReleaseCheckError: Error, Equatable, LocalizedError {
    case invalidCurrentVersion(String)
    case invalidResponse
    case httpStatus(Int)
    case invalidRelease
    case untrustedReleaseURL

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion:
            "The installed app version is invalid."
        case .invalidResponse:
            "GitHub returned an invalid response."
        case .httpStatus(let status):
            "GitHub returned HTTP status \(status)."
        case .invalidRelease:
            "The latest GitHub release has invalid metadata."
        case .untrustedReleaseURL:
            "GitHub returned an untrusted release URL."
        }
    }
}

struct ReleaseCheckService: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/tcballard/LocalWrap/releases/latest"
    )!

    private let fetch: Fetch

    init(fetch: @escaping Fetch = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.fetch = fetch
    }

    func check(currentVersion: String) async throws -> ReleaseCheckOutcome {
        guard let current = SemanticVersion(currentVersion) else {
            throw ReleaseCheckError.invalidCurrentVersion(currentVersion)
        }
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LocalWrapMac/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else {
            throw ReleaseCheckError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReleaseCheckError.httpStatus(http.statusCode)
        }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw ReleaseCheckError.invalidRelease
        }
        guard !release.draft, !release.prerelease,
              let latest = SemanticVersion(release.tagName) else {
            throw ReleaseCheckError.invalidRelease
        }
        guard Self.isTrustedReleaseURL(release.htmlURL) else {
            throw ReleaseCheckError.untrustedReleaseURL
        }
        if latest > current {
            return .updateAvailable(
                currentVersion: current.description,
                latestVersion: latest.description,
                releaseURL: release.htmlURL
            )
        }
        return .upToDate(
            currentVersion: current.description,
            latestVersion: latest.description
        )
    }

    static func isTrustedReleaseURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/tcballard/LocalWrap/releases/")
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft, prerelease
    }
}

private struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        value = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        value = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]), major >= 0,
              let minor = Int(components[1]), minor >= 0,
              let patch = Int(components[2]), patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
