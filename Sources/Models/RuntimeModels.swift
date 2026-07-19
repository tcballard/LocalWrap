import Foundation

enum RuntimeStatus: String, Equatable, Sendable {
    case stopped
    case starting
    case ready
    case runningUnresponsive = "running-unresponsive"
    case stopping
    case failed

    var isActive: Bool {
        switch self {
        case .starting, .ready, .runningUnresponsive, .stopping:
            true
        case .stopped, .failed:
            false
        }
    }
}

enum RuntimeBootstrapState: Equatable, Sendable {
    case ready
    case reconciling
    case blocked(String)

    var permitsMutation: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum RuntimeOwnershipReason: String, Equatable, Sendable {
    case ledgerUnavailable = "ledger-unavailable"
    case inspectionUnavailable = "inspection-unavailable"
    case permissionDenied = "permission-denied"
    case identityMismatch = "identity-mismatch"
    case projectConfigurationChanged = "project-configuration-changed"
    case processGroupMismatch = "process-group-mismatch"
}

enum RuntimeOwnershipState: Equatable, Sendable {
    case none
    case reconciling
    case verified(runID: String)
    case unverifiable(runID: String, reason: RuntimeOwnershipReason)
    case conflicting(runID: String, reason: RuntimeOwnershipReason)

    var permitsSignalling: Bool {
        if case .verified = self { return true }
        return false
    }

    var hasUnresolvedRun: Bool {
        switch self {
        case .none: false
        case .reconciling, .verified, .unverifiable, .conflicting: true
        }
    }

    var requiresOwnershipReview: Bool {
        switch self {
        case .none, .verified:
            false
        case .reconciling, .unverifiable, .conflicting:
            true
        }
    }
}

enum RuntimeTerminalReason: Equatable, Sendable {
    case intentionalStop
    case launchFailure
    case doctorBlocked
    case readinessTimeout
    case cleanupFailure
    case unexpectedExit(code: Int32?)
    case ownershipConflict
    case ownershipUnverifiable
}

enum RuntimeReconciliationClassification: String, Equatable, Sendable {
    case exited
    case verifiedOwned = "verified-owned"
    case unverifiable
    case conflicting
}

struct RuntimeReconciliationItem: Equatable, Sendable {
    let runID: String
    let projectID: String
    let classification: RuntimeReconciliationClassification
    let message: String
}

struct RuntimeReconciliationReport: Equatable, Sendable {
    let items: [RuntimeReconciliationItem]
    let ledgerError: String?

    static let empty = RuntimeReconciliationReport(items: [], ledgerError: nil)
    var unresolvedItems: [RuntimeReconciliationItem] {
        items.filter { $0.classification == .unverifiable || $0.classification == .conflicting }
    }
    var canLaunch: Bool { ledgerError == nil }
}

struct RuntimeShutdownFailure: Equatable, Sendable {
    let projectID: String
    let runID: String?
    let message: String
}

struct RuntimeShutdownReport: Equatable, Sendable {
    let stoppedProjectIDs: [String]
    let failures: [RuntimeShutdownFailure]

    static let empty = RuntimeShutdownReport(stoppedProjectIDs: [], failures: [])
    var canTerminate: Bool { failures.isEmpty }
}

struct RuntimeSnapshot: Equatable, Sendable {
    static let maximumLogLines = 500

    var status: RuntimeStatus = .stopped
    var runID: String?
    var ownership: RuntimeOwnershipState = .none
    var terminalReason: RuntimeTerminalReason?
    var recoveredAfterRelaunch = false
    var pid: Int32?
    var logs: [String] = []
    var startedAt: String?
    var stoppedAt: String?
    var readyAt: String?
    var exitCode: Int32?
    var readinessMessage: String?
    var error: String?
    var diagnosis: ProjectDiagnosis = .notChecked()

    mutating func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > Self.maximumLogLines {
            logs.removeFirst(logs.count - Self.maximumLogLines)
        }
    }
}

struct ParsedCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}

enum RuntimeError: Error, Equatable, LocalizedError {
    case emptyCommand
    case disallowedCharacters
    case executableNotAllowed(String)
    case executableNotFound(String)
    case workingDirectoryMissing(String)
    case alreadyRunning
    case launchFailed(String)
    case doctorBlocked(String)
    case reconciliationRequired(String)
    case ownershipNotVerified(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "No command provided."
        case .disallowedCharacters:
            "Command contains disallowed shell characters."
        case .executableNotAllowed(let executable):
            "Command \"\(executable)\" is not allowed."
        case .executableNotFound(let executable):
            "Could not find \(executable) in PATH."
        case .workingDirectoryMissing(let path):
            "Working directory does not exist: \(path)"
        case .alreadyRunning:
            "Project is already running."
        case .launchFailed(let message):
            "Project failed to launch: \(message)"
        case .doctorBlocked(let message):
            message
        case .reconciliationRequired(let message), .ownershipNotVerified(let message):
            message
        }
    }
}
