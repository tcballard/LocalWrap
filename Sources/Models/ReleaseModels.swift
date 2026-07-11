import Foundation

enum ReleaseCheckOutcome: Equatable, Sendable {
    case upToDate(currentVersion: String, latestVersion: String)
    case updateAvailable(currentVersion: String, latestVersion: String, releaseURL: URL)
}

struct ReleaseNotice: Equatable, Identifiable, Sendable {
    let title: String
    let message: String
    let releaseURL: URL?

    var id: String { "\(title)|\(message)|\(releaseURL?.absoluteString ?? "")" }
}
