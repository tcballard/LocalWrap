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

struct RuntimeSnapshot: Equatable, Sendable {
    static let maximumLogLines = 500

    var status: RuntimeStatus = .stopped
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
        }
    }
}
