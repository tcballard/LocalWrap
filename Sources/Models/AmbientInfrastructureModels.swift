import Foundation

enum LaunchAtLoginStatus: String, Equatable, Sendable {
    case notRegistered = "not-registered"
    case enabled
    case requiresApproval = "requires-approval"
    case notFound = "not-found"

    /// `requiresApproval` means the user has requested the login item but
    /// macOS still requires an approval in System Settings.
    var isRequested: Bool {
        self == .enabled || self == .requiresApproval
    }

    var label: String {
        switch self {
        case .notRegistered: "Off"
        case .enabled: "On"
        case .requiresApproval: "Approval Required"
        case .notFound: "Unavailable"
        }
    }
}

enum LaunchAtLoginOperation: Equatable, Sendable {
    case idle
    case enabling
    case disabling

    var isInProgress: Bool { self != .idle }
}

enum LaunchAtLoginServiceError: Error, Equatable, LocalizedError, Sendable {
    case operationInProgress
    case unavailable
    case enableFailed(String)
    case disableFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "Another Launch at Login change is already in progress."
        case .unavailable:
            "Launch at Login is unavailable for this copy of LocalWrap."
        case .enableFailed(let detail):
            "Launch at Login could not be enabled. \(detail)"
        case .disableFailed(let detail):
            "Launch at Login could not be disabled. \(detail)"
        }
    }
}

enum LocalNotificationAuthorizationStatus: String, Equatable, Sendable {
    case unknown
    case notDetermined = "not-determined"
    case denied
    case authorized
    case provisional

    var permitsDelivery: Bool {
        self == .authorized || self == .provisional
    }
}

enum RuntimeNotificationPreferenceStatus: Equatable, Sendable {
    case disabled
    case checkingAuthorization
    case requestingAuthorization
    case enabled
    case requiresSystemApproval

    var isBusy: Bool {
        self == .checkingAuthorization || self == .requestingAuthorization
    }

    var label: String {
        switch self {
        case .disabled: "Off"
        case .checkingAuthorization: "Checking"
        case .requestingAuthorization: "Requesting Permission"
        case .enabled: "On"
        case .requiresSystemApproval: "Permission Required"
        }
    }
}

enum RuntimeNotificationKind: String, Equatable, Sendable {
    case ready
    case failed
    case unexpectedExit = "unexpected-exit"
}

/// Notification content is deliberately bounded and redacted. It never
/// carries paths, commands, URLs, ports, logs, errors, or environment values.
struct RuntimeNotificationRequest: Equatable, Sendable {
    let identifier: String
    let threadIdentifier: String
    let kind: RuntimeNotificationKind
    let title: String
    let body: String
}

enum RuntimeNotificationServiceError: Error, Equatable, LocalizedError, Sendable {
    case authorizationFailed(String)
    case deliveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationFailed(let detail):
            "Notification permission could not be checked. \(detail)"
        case .deliveryFailed(let detail):
            "A runtime notification could not be delivered. \(detail)"
        }
    }
}
