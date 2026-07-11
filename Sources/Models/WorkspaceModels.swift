import Foundation

enum WorkspaceTarget: Hashable, Equatable, Sendable {
    case profile(String)
    case lastRunning
    case allProjects

    var profileID: String? {
        if case .profile(let id) = self { return id }
        return nil
    }
}

enum WorkspaceTargetKind: String, Equatable, Sendable {
    case profile
    case lastRunning = "last-running"
    case allProjects = "all-projects"
}

struct ResolvedWorkspaceTarget: Equatable, Sendable {
    let kind: WorkspaceTargetKind
    let profileID: String?
    let name: String
    let projectIDs: [String]
}

enum WorkspaceDoctorStatus: String, Equatable, Sendable {
    case empty
    case ready
    case attention
    case blocked
}

enum WorkspaceCheckStatus: String, Equatable, Sendable {
    case pending
    case pass
    case warn
    case fail
}

enum WorkspaceCheckID: String, CaseIterable, Equatable, Sendable {
    case projects
    case startup
    case directories
    case commands
    case dependencies
    case environment
    case ports
    case urls

    var label: String {
        switch self {
        case .projects: "Projects"
        case .startup: "Startup"
        case .directories: "Directories"
        case .commands: "Commands"
        case .dependencies: "Dependencies"
        case .environment: "Environment"
        case .ports: "Ports"
        case .urls: "URLs"
        }
    }
}

struct WorkspaceDoctorCheck: Identifiable, Equatable, Sendable {
    let id: WorkspaceCheckID
    let status: WorkspaceCheckStatus
    let message: String
    var label: String { id.label }
}

enum WorkspaceIssueSeverity: String, Equatable, Sendable {
    case warning
    case blocker
}

struct WorkspaceIssue: Identifiable, Equatable, Sendable {
    let severity: WorkspaceIssueSeverity
    let check: WorkspaceCheckID
    let code: String
    let message: String
    var id: String { "\(check.rawValue)|\(code)|\(message)" }
}

enum WorkspaceProjectStatus: String, Equatable, Sendable {
    case ready
    case attention
    case blocked
}

struct WorkspaceProjectDiagnosis: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: WorkspaceProjectStatus
    let summary: String
    let dependencyNames: [String]
    let issues: [WorkspaceIssue]
}

struct WorkspaceDiagnosisTotals: Equatable, Sendable {
    let projects: Int
    let ready: Int
    let warnings: Int
    let blockers: Int
}

struct WorkspaceDiagnosis: Equatable, Sendable {
    let status: WorkspaceDoctorStatus
    let summary: String
    let updatedAt: String
    let target: ResolvedWorkspaceTarget
    let totals: WorkspaceDiagnosisTotals
    let startableProjectIDs: [String]
    let blockedProjectIDs: [String]
    let checks: [WorkspaceDoctorCheck]
    let projects: [WorkspaceProjectDiagnosis]
}

enum WorkspaceOperationItemStatus: String, Equatable, Sendable {
    case started
    case failed
    case skipped
    case blocked
}

struct WorkspaceOperationResult: Identifiable, Equatable, Sendable {
    let projectID: String
    let projectName: String
    let status: WorkspaceOperationItemStatus
    let reason: String?
    let message: String
    let blockedByProjectIDs: [String]
    let blockedByProjectNames: [String]
    var id: String { projectID }
}

struct WorkspaceOperationSummary: Equatable, Sendable {
    let results: [WorkspaceOperationResult]
    var started: Int { results.count { $0.status == .started } }
    var failed: Int { results.count { $0.status == .failed } }
    var skipped: Int { results.count { $0.status == .skipped } }
    var blocked: Int { results.count { $0.status == .blocked } }
}

struct WorkspacePackV1: Codable, Equatable, Sendable {
    var localwrap: Int
    var name: String?
    var projects: [WorkspacePackProject]
    var workspaces: [WorkspacePackProfile]?
}

struct WorkspacePackProject: Codable, Equatable, Sendable {
    var id: String?
    var name: String?
    var path: String?
    var command: String
    var port: Int?
    var url: String?
    var autostart: Bool?
    var openOnReady: Bool?
    var dependsOn: [String]?
    var healthCheck: HealthCheck?

    private enum CodingKeys: String, CodingKey {
        case id, name, path, command, port, url, autostart, openOnReady, dependsOn, healthCheck
    }

    init(
        id: String? = nil,
        name: String? = nil,
        path: String? = nil,
        command: String,
        port: Int? = nil,
        url: String? = nil,
        autostart: Bool? = nil,
        openOnReady: Bool? = nil,
        dependsOn: [String]? = nil,
        healthCheck: HealthCheck? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.command = command
        self.port = port
        self.url = url
        self.autostart = autostart
        self.openOnReady = openOnReady
        self.dependsOn = dependsOn
        self.healthCheck = healthCheck
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        port = try? values.decodeIfPresent(Int.self, forKey: .port)
        if port == nil, let text = try? values.decode(String.self, forKey: .port) {
            port = Int(text)
        }
        url = try values.decodeIfPresent(String.self, forKey: .url)
        autostart = try values.decodeIfPresent(Bool.self, forKey: .autostart)
        openOnReady = try values.decodeIfPresent(Bool.self, forKey: .openOnReady)
        dependsOn = try values.decodeIfPresent([String].self, forKey: .dependsOn)
        healthCheck = try values.decodeIfPresent(HealthCheck.self, forKey: .healthCheck)
    }
}

struct WorkspacePackProfile: Codable, Equatable, Sendable {
    var id: String?
    var name: String?
    var projects: [String]?
}

struct ReviewedWorkspacePack: Equatable, Sendable {
    let name: String
    let rootURL: URL
    let packURL: URL
    let projects: [ReviewedWorkspacePackProject]
    let profiles: [ReviewedWorkspacePackProfile]
}

struct ReviewedWorkspacePackProject: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    var draft: ProjectDraft
}

struct ReviewedWorkspacePackProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let projectIDs: [String]
}

struct WorkspacePackExportResult: Equatable, Sendable {
    let pack: WorkspacePackV1
    let skippedProjects: [WorkspacePackSkippedProject]
}

struct WorkspacePackSkippedProject: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let reason: String
}

enum WorkspaceError: Error, Equatable, LocalizedError {
    case profileNotFound
    case operationInProgress
    case noProjects
    case pack(String)

    var errorDescription: String? {
        switch self {
        case .profileNotFound: "Workspace not found."
        case .operationInProgress: "A workspace operation is already in progress."
        case .noProjects: "No projects are selected."
        case .pack(let message): message
        }
    }
}
