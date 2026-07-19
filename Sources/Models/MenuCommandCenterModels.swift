import Foundation

enum MenuProjectConfigurationPolicy: Equatable, Sendable {
    case pending
    case valid
    case invalid(firstFailureField: ProjectField)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var firstFailureField: ProjectField? {
        if case .invalid(let field) = self { return field }
        return nil
    }

    var requiresReview: Bool {
        if case .invalid = self { return true }
        return false
    }
}

enum MenuRuntimeSignallingCapability: Equatable, Sendable {
    case unavailable(MenuRuntimeSignallingUnavailableReason)
    case verified(runID: String)

    var permitsSignalling: Bool {
        if case .verified = self { return true }
        return false
    }

    var disabledReason: String? {
        if case .unavailable(let reason) = self { return reason.label }
        return nil
    }
}

enum MenuRuntimeSignallingUnavailableReason: Equatable, Sendable {
    case noOwnedProcess
    case reconciling
    case ownershipUnverifiable
    case ownershipConflict
    case runIdentityChanged

    var label: String {
        switch self {
        case .noOwnedProcess: "No verified owned process is available."
        case .reconciling: "Runtime ownership is still being reconciled."
        case .ownershipUnverifiable: "Runtime ownership could not be verified."
        case .ownershipConflict: "Runtime ownership conflicts with the saved run."
        case .runIdentityChanged: "The verified run changed. Refresh LocalWrap and try again."
        }
    }
}

enum MenuWorkspaceValidationBlockReason: Equatable, Sendable {
    case validationPending
    case noProjects
    case configuration
    case dependencies
    case environment
    case ports
    case urls

    var label: String {
        switch self {
        case .validationPending: "Workspace validation must finish first."
        case .noProjects: "The workspace has no projects."
        case .configuration: "A project configuration needs review."
        case .dependencies: "Workspace dependencies need review."
        case .environment: "Workspace environment checks need review."
        case .ports: "Workspace ports need review."
        case .urls: "Workspace URLs need review."
        }
    }
}

enum MenuWorkspaceValidationState: Equatable, Sendable {
    case ready
    case blocked(MenuWorkspaceValidationBlockReason)
}

struct MenuWorkspaceValidatedPolicy: Equatable, Sendable {
    let target: WorkspaceTarget
    let projectIDs: [String]
    let validation: MenuWorkspaceValidationState
}

/// Immutable policy prepared away from menu presentation. The command-center
/// projection performs no filesystem reads, URL parsing, or Doctor diagnosis.
struct MenuProjectValidatedPolicy: Equatable, Sendable {
    let projectID: String
    let configuration: MenuProjectConfigurationPolicy
    let canOpenValidatedLocalURL: Bool
    let signalling: MenuRuntimeSignallingCapability

    static func unavailable(projectID: String) -> MenuProjectValidatedPolicy {
        MenuProjectValidatedPolicy(
            projectID: projectID,
            configuration: .pending,
            canOpenValidatedLocalURL: false,
            signalling: .unavailable(.noOwnedProcess)
        )
    }
}

struct MenuCommandCenterInput: Equatable, Sendable {
    let projects: [Project]
    let runtimes: [String: RuntimeSnapshot]
    let policies: [String: MenuProjectValidatedPolicy]
    let workspacePolicies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy]
    let workspace: WorkspaceState
    let attention: AttentionSnapshot
    let permitsRuntimeMutation: Bool
    let workspaceOperationInProgress: Bool

    init(
        projects: [Project],
        runtimes: [String: RuntimeSnapshot] = [:],
        policies: [String: MenuProjectValidatedPolicy] = [:],
        workspacePolicies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy] = [:],
        workspace: WorkspaceState = .empty,
        attention: AttentionSnapshot = .empty,
        permitsRuntimeMutation: Bool = true,
        workspaceOperationInProgress: Bool = false
    ) {
        self.projects = projects
        self.runtimes = runtimes
        self.policies = policies
        self.workspacePolicies = workspacePolicies
        self.workspace = workspace
        self.attention = attention
        self.permitsRuntimeMutation = permitsRuntimeMutation
        self.workspaceOperationInProgress = workspaceOperationInProgress
    }
}

enum MenuCommandCenterGroupKind: String, CaseIterable, Equatable, Sendable {
    case attention
    case running
    case ready
    case readyToStart = "ready-to-start"

    var title: String {
        switch self {
        case .attention: "Attention"
        case .running: "Running"
        case .ready: "Ready"
        case .readyToStart: "Ready to Start"
        }
    }
}

enum MenuCommandCenterItemKind: String, Equatable, Sendable {
    case attentionIssue = "attention-issue"
    case runtimeFailure = "runtime-failure"
    case configurationIssue = "configuration-issue"
    case project
}

struct MenuCommandCenterItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: MenuCommandCenterItemKind
    let title: String
    let contextLabel: String?
    let statusLabel: String
    let detailLabel: String?
    let projectID: String?
    let attentionIssueID: String?
    let reviewTarget: AttentionNavigationTarget?
}

struct MenuCommandCenterGroup: Identifiable, Equatable, Sendable {
    var id: MenuCommandCenterGroupKind { kind }

    let kind: MenuCommandCenterGroupKind
    let title: String
    let items: [MenuCommandCenterItem]
    let totalCount: Int

    var count: Int { totalCount }
    var visibleCount: Int { items.count }
    var hasOverflow: Bool { totalCount > items.count }
}

enum MenuCommandCenterPrimaryActionKind: String, Equatable, Sendable {
    case resume
    case openReadyApps = "open-ready-apps"
    case reviewFailure = "review-failure"

    var label: String {
        switch self {
        case .resume: "Resume"
        case .openReadyApps: "Open Ready Apps"
        case .reviewFailure: "Review Failure"
        }
    }
}

enum MenuProjectAction: Equatable, Sendable {
    case start
    case stop
    case restart
    case open
    case review
}

enum MenuWorkspaceAction: Equatable, Sendable {
    case resume
    case startAll
    case stopAll
    case openReadyApps
    case startSavedProfile(String)
}

struct MenuCommandCenterPrimaryAction: Equatable, Sendable {
    let kind: MenuCommandCenterPrimaryActionKind
    let projectIDs: [String]
    let workspaceTarget: WorkspaceTarget?
    let attentionIssueID: String?
    let reviewTarget: AttentionNavigationTarget?

    var label: String { kind.label }
}

struct MenuActionCapability: Equatable, Sendable {
    let isEnabled: Bool
    let disabledReason: String?

    static let enabled = MenuActionCapability(isEnabled: true, disabledReason: nil)

    static func disabled(_ reason: String) -> MenuActionCapability {
        MenuActionCapability(isEnabled: false, disabledReason: reason)
    }
}

struct MenuProjectQuickActions: Identifiable, Equatable, Sendable {
    var id: String { projectID }

    let projectID: String
    let start: MenuActionCapability
    let stop: MenuActionCapability
    let restart: MenuActionCapability
    let open: MenuActionCapability
    let review: MenuActionCapability
}

struct MenuWorkspaceQuickActions: Equatable, Sendable {
    let resume: MenuActionCapability
    let resumeProjectIDs: [String]
    let startAll: MenuActionCapability
    let startAllProjectIDs: [String]
    let stopAll: MenuActionCapability
    let stopAllProjectIDs: [String]
    let openReadyApps: MenuActionCapability
    let readyProjectIDs: [String]
    let savedWorkspaces: [MenuSavedWorkspaceQuickAction]
    let savedWorkspaceTotalCount: Int
}

struct MenuSavedWorkspaceQuickAction: Identifiable, Equatable, Sendable {
    var id: String { profileID }

    let profileID: String
    let name: String
    let projectIDs: [String]
    let start: MenuActionCapability
}

struct MenuCommandCenterEmptyState: Equatable, Sendable {
    let title: String
    let detail: String
}

struct MenuCommandCenterSnapshot: Equatable, Sendable {
    let groups: [MenuCommandCenterGroup]
    let primaryAction: MenuCommandCenterPrimaryAction?
    let projectQuickActions: [MenuProjectQuickActions]
    let projectQuickActionTotalCount: Int
    let workspaceQuickActions: MenuWorkspaceQuickActions
    let statusLabel: String
    let emptyState: MenuCommandCenterEmptyState?
    let showInLocalWrap: MenuActionCapability

    var hasOverflow: Bool {
        groups.contains(where: \.hasOverflow)
            || projectQuickActionTotalCount > projectQuickActions.count
            || workspaceQuickActions.savedWorkspaceTotalCount
                > workspaceQuickActions.savedWorkspaces.count
    }

    /// Menus render only populated groups; the stable full group set remains
    /// available for deterministic lookup and tests.
    var visibleGroups: [MenuCommandCenterGroup] {
        groups.filter { !$0.items.isEmpty }
    }

    func group(_ kind: MenuCommandCenterGroupKind) -> MenuCommandCenterGroup {
        groups.first { $0.kind == kind }
            ?? MenuCommandCenterGroup(
                kind: kind,
                title: kind.title,
                items: [],
                totalCount: 0
            )
    }

    func quickActions(for projectID: String) -> MenuProjectQuickActions? {
        projectQuickActions.first { $0.projectID == projectID }
    }
}
