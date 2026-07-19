import Foundation

enum AttentionSeverity: String, Equatable, Hashable, Sendable {
    case warning
    case blocker
}

enum AttentionSource: String, CaseIterable, Equatable, Hashable, Sendable {
    case projectDoctor = "project-doctor"
    case workspaceDoctor = "workspace-doctor"
    case runtime
    case workspaceOperation = "workspace-operation"
    case preview
}

enum AttentionScopeKind: String, Equatable, Hashable, Sendable {
    case application
    case workspace
    case project
}

enum AttentionScope: Equatable, Sendable {
    case application
    case workspace(id: String, name: String)
    case project(id: String, name: String)

    var kind: AttentionScopeKind {
        switch self {
        case .application: .application
        case .workspace: .workspace
        case .project: .project
        }
    }

    var displayName: String {
        switch self {
        case .application: "LocalWrap"
        case .workspace(_, let name), .project(_, let name): name
        }
    }
}

enum AttentionProjectSurface: Equatable, Sendable {
    case field(ProjectField)
    case doctor(check: DoctorCheckID, suggestedAction: DoctorActionID?)
    case runtime
    case preview
}

enum AttentionNavigationTarget: Equatable, Sendable {
    case attention
    case project(projectID: String, surface: AttentionProjectSurface)
    case workspace(target: WorkspaceTarget, projectID: String?)
}

enum AttentionActionKind: Equatable, Sendable {
    case navigate
    case doctor(DoctorActionID)
    case retryPreview
    case reconcileRuntime
}

struct AttentionNextAction: Equatable, Sendable {
    let label: String
    let kind: AttentionActionKind
    let requiresConfirmation: Bool
}

struct AttentionIssue: Identifiable, Equatable, Sendable {
    static let maximumTitleBytes = 160
    static let maximumConsequenceBytes = 320
    static let maximumActionLabelBytes = 240
    static let maximumScopeNameBytes = 160

    let id: String
    let severity: AttentionSeverity
    let sources: [AttentionSource]
    let scope: AttentionScope
    let title: String
    let consequence: String
    let nextAction: AttentionNextAction
    let navigationTarget: AttentionNavigationTarget
}

enum AttentionHistoryEvent: String, Equatable, Sendable {
    case opened
    case updated
    case resolved
}

/// A deliberately redacted diagnostic event. It stores only an opaque issue
/// identity and coarse categories. User-authored names, paths, URLs, commands,
/// log lines, error messages, and environment values never enter history.
struct AttentionHistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let issueID: String
    let event: AttentionHistoryEvent
    let recordedAt: String
    let severity: AttentionSeverity
    let sources: [AttentionSource]
    let scopeKind: AttentionScopeKind
}

struct AttentionSnapshot: Equatable, Sendable {
    let generatedAt: String
    let issues: [AttentionIssue]
    let history: [AttentionHistoryEntry]

    var count: Int { issues.count }
    var blockerCount: Int { issues.count { $0.severity == .blocker } }
    var warningCount: Int { issues.count { $0.severity == .warning } }

    static let empty = AttentionSnapshot(generatedAt: "", issues: [], history: [])
}

struct AttentionInput: Sendable {
    var projects: [Project]
    var runtimes: [String: RuntimeSnapshot]
    var projectDiagnoses: [String: ProjectDiagnosis]
    var workspaceDiagnoses: [WorkspaceDiagnosis]
    var workspaceOperations: [WorkspaceOperationSummary]
    var previews: [String: PreviewState]
    var runtimeReconciliation: RuntimeReconciliationReport

    /// The plural properties are the canonical API. The singular arguments
    /// are migration shims so callers can move to retained, all-workspace
    /// evidence without one large integration change.
    init(
        projects: [Project] = [],
        runtimes: [String: RuntimeSnapshot] = [:],
        projectDiagnoses: [String: ProjectDiagnosis] = [:],
        workspaceDiagnoses: [WorkspaceDiagnosis] = [],
        workspaceOperations: [WorkspaceOperationSummary] = [],
        workspaceDiagnosis: WorkspaceDiagnosis? = nil,
        workspaceOperation: WorkspaceOperationSummary? = nil,
        previews: [String: PreviewState] = [:],
        runtimeReconciliation: RuntimeReconciliationReport = .empty
    ) {
        self.projects = projects
        self.runtimes = runtimes
        self.projectDiagnoses = projectDiagnoses
        self.workspaceDiagnoses = workspaceDiagnoses + (workspaceDiagnosis.map { [$0] } ?? [])
        self.workspaceOperations = workspaceOperations + (workspaceOperation.map { [$0] } ?? [])
        self.previews = previews
        self.runtimeReconciliation = runtimeReconciliation
    }
}
