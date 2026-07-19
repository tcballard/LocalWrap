import Foundation

/// Builds the menu-bar command-center from immutable, precomputed evidence.
/// This type intentionally has no filesystem, URL, or Doctor dependencies so
/// calling it from a menu-open path is deterministic and non-blocking.
struct MenuCommandCenterService: Sendable {
    private static let maximumItemsPerGroup = 8
    // Every visible group row must retain its fixed action set. Four groups
    // can each expose eight distinct projects, so 32 is the smallest bound
    // that cannot strand a visible row without capabilities.
    private static let maximumProjectQuickActions = 32
    static let maximumSavedWorkspaceQuickActions = 6
    private static let maximumProjects = 128
    private static let maximumAttentionIssues = 128

    /// The main window owns the complete workspace list. Only profiles that
    /// can actually appear as menu shortcuts need target-specific background
    /// diagnosis, keeping refresh work small and deterministic.
    static func profilesRequiringPolicy(
        _ profiles: [WorkspaceProfile]
    ) -> [WorkspaceProfile] {
        var seen = Set<String>()
        return profiles
            .sorted(by: Self.workspaceProfileOrder)
            .filter { seen.insert($0.id).inserted }
            .prefix(Self.maximumSavedWorkspaceQuickActions)
            .map { $0 }
    }

    func snapshot(
        projects: [Project],
        runtimes: [String: RuntimeSnapshot],
        policies: [String: MenuProjectValidatedPolicy],
        workspacePolicies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy],
        workspace: WorkspaceState,
        attention: AttentionSnapshot,
        permitsRuntimeMutation: Bool = true,
        workspaceOperationInProgress: Bool = false
    ) -> MenuCommandCenterSnapshot {
        snapshot(MenuCommandCenterInput(
            projects: projects,
            runtimes: runtimes,
            policies: policies,
            workspacePolicies: workspacePolicies,
            workspace: workspace,
            attention: attention,
            permitsRuntimeMutation: permitsRuntimeMutation,
            workspaceOperationInProgress: workspaceOperationInProgress
        ))
    }

    func snapshot(_ input: MenuCommandCenterInput) -> MenuCommandCenterSnapshot {
        let projects = uniqueSortedProjects(input.projects)
        let projectIDs = Set(projects.map(\.id))
        let attentionProjectIDs = Set(
            input.attention.issues.prefix(Self.maximumAttentionIssues).compactMap {
                projectID(from: $0.scope)
            }
        )
        let startBlockReason = startMutationBlockReason(input)
        let stopBlockReason = stopMutationBlockReason(input)
        let quickActions = projects.map { project in
            projectQuickActions(
                project: project,
                runtime: input.runtimes[project.id] ?? RuntimeSnapshot(),
                policy: matchingPolicy(for: project.id, in: input.policies),
                hasAttention: attentionProjectIDs.contains(project.id),
                startMutationBlockReason: startBlockReason,
                stopMutationBlockReason: stopBlockReason
            )
        }
        let actionsByProjectID = Dictionary(
            uniqueKeysWithValues: quickActions.map { ($0.projectID, $0) }
        )

        let attentionItems = makeAttentionItems(
            attention: input.attention,
            projects: projects,
            runtimes: input.runtimes,
            policies: input.policies,
            quickActions: actionsByProjectID
        )
        let runningItems = projects.compactMap { project -> MenuCommandCenterItem? in
            let runtime = input.runtimes[project.id] ?? RuntimeSnapshot()
            switch runtime.status {
            case .starting, .runningUnresponsive, .stopping:
                return projectItem(project, runtime: runtime)
            case .stopped, .ready, .failed:
                return nil
            }
        }
        let readyItems = projects.compactMap { project -> MenuCommandCenterItem? in
            let runtime = input.runtimes[project.id] ?? RuntimeSnapshot()
            return runtime.status == .ready ? projectItem(project, runtime: runtime) : nil
        }
        let readyToStartItems = projects.compactMap { project -> MenuCommandCenterItem? in
            let runtime = input.runtimes[project.id] ?? RuntimeSnapshot()
            guard runtime.status == .stopped,
                  actionsByProjectID[project.id]?.start.isEnabled == true else { return nil }
            return projectItem(project, runtime: runtime)
        }

        let groups = [
            group(
                .attention,
                items: attentionItems,
                totalCount: max(attentionItems.count, input.attention.issues.count)
            ),
            group(.running, items: runningItems),
            group(.ready, items: readyItems),
            group(.readyToStart, items: readyToStartItems),
        ]
        let workspaceActions = workspaceQuickActions(
            projects: projects,
            projectIDs: projectIDs,
            runtimes: input.runtimes,
            workspace: input.workspace,
            projectActions: actionsByProjectID,
            workspacePolicies: input.workspacePolicies,
            startMutationBlockReason: startBlockReason,
            stopMutationBlockReason: stopBlockReason
        )
        let primaryAction = primaryAction(
            attentionItems: attentionItems,
            projects: projects,
            runtimes: input.runtimes,
            workspaceActions: workspaceActions
        )
        let visibleQuickActions = boundedQuickActions(
            groups: groups,
            all: quickActions
        )
        let isCompactEmpty = projects.isEmpty && input.attention.issues.isEmpty

        return MenuCommandCenterSnapshot(
            groups: groups,
            primaryAction: primaryAction,
            projectQuickActions: visibleQuickActions,
            projectQuickActionTotalCount: input.projects.count,
            workspaceQuickActions: workspaceActions,
            statusLabel: isCompactEmpty ? "No projects" : statusLabel(groups: groups),
            emptyState: isCompactEmpty
                ? MenuCommandCenterEmptyState(
                    title: "No projects yet",
                    detail: "Open LocalWrap to add your first project."
                )
                : nil,
            showInLocalWrap: .enabled
        )
    }

    private func matchingPolicy(
        for projectID: String,
        in policies: [String: MenuProjectValidatedPolicy]
    ) -> MenuProjectValidatedPolicy {
        guard let policy = policies[projectID], policy.projectID == projectID else {
            return .unavailable(projectID: projectID)
        }
        return policy
    }

    private func boundedQuickActions(
        groups: [MenuCommandCenterGroup],
        all: [MenuProjectQuickActions]
    ) -> [MenuProjectQuickActions] {
        let byProjectID = Dictionary(
            uniqueKeysWithValues: all.map { ($0.projectID, $0) }
        )
        var seen = Set<String>()
        var result: [MenuProjectQuickActions] = []

        // Capabilities for rows the user can see take precedence over filler
        // entries. This preserves the fixed action submenu even when visible
        // groups contain projects outside the first global sort page.
        for item in groups.flatMap(\.items) {
            guard let projectID = item.projectID,
                  seen.insert(projectID).inserted,
                  let actions = byProjectID[projectID] else { continue }
            result.append(actions)
        }
        for actions in all where seen.insert(actions.projectID).inserted {
            result.append(actions)
        }
        return Array(result.prefix(Self.maximumProjectQuickActions))
    }

    private func uniqueSortedProjects(_ projects: [Project]) -> [Project] {
        var seen = Set<String>()
        return Array(projects.prefix(Self.maximumProjects))
            .sorted(by: projectOrder)
            .filter { seen.insert($0.id).inserted }
    }

    private func projectOrder(_ lhs: Project, _ rhs: Project) -> Bool {
        let left = Self.menuText(lhs.name, fallback: "Unnamed Project", maximumBytes: 80)
            .lowercased()
        let right = Self.menuText(rhs.name, fallback: "Unnamed Project", maximumBytes: 80)
            .lowercased()
        return left == right ? lhs.id < rhs.id : left < right
    }

    private func itemOrder(_ lhs: MenuCommandCenterItem, _ rhs: MenuCommandCenterItem) -> Bool {
        let left = lhs.title.lowercased()
        let right = rhs.title.lowercased()
        return left == right ? lhs.id < rhs.id : left < right
    }

    private func group(
        _ kind: MenuCommandCenterGroupKind,
        items: [MenuCommandCenterItem],
        totalCount: Int? = nil
    ) -> MenuCommandCenterGroup {
        let ordered = kind == .attention ? items : items.sorted(by: itemOrder)
        return MenuCommandCenterGroup(
            kind: kind,
            title: kind.title,
            items: Array(ordered.prefix(Self.maximumItemsPerGroup)),
            totalCount: max(ordered.count, totalCount ?? 0)
        )
    }

    private func projectItem(_ project: Project, runtime: RuntimeSnapshot) -> MenuCommandCenterItem {
        MenuCommandCenterItem(
            id: "project:\(project.id)",
            kind: .project,
            title: Self.menuText(
                project.name,
                fallback: "Unnamed Project",
                maximumBytes: 80
            ),
            contextLabel: nil,
            statusLabel: runtimeStatusLabel(runtime),
            detailLabel: runtimeDetail(runtime),
            projectID: project.id,
            attentionIssueID: nil,
            reviewTarget: .project(projectID: project.id, surface: .runtime)
        )
    }

    private func makeAttentionItems(
        attention: AttentionSnapshot,
        projects: [Project],
        runtimes: [String: RuntimeSnapshot],
        policies: [String: MenuProjectValidatedPolicy],
        quickActions: [String: MenuProjectQuickActions]
    ) -> [MenuCommandCenterItem] {
        let boundedIssues = attention.issues.prefix(Self.maximumAttentionIssues)
        var items = boundedIssues.map { issue in
            MenuCommandCenterItem(
                id: "attention:\(issue.id)",
                kind: .attentionIssue,
                title: Self.menuText(
                    issue.title,
                    fallback: "Review issue",
                    maximumBytes: 96
                ),
                contextLabel: Self.menuText(
                    issue.scope.displayName,
                    fallback: "LocalWrap",
                    maximumBytes: 80
                ),
                statusLabel: issue.severity == .blocker
                    ? "Failure — action required"
                    : "Warning — review recommended",
                detailLabel: Self.menuText(
                    issue.consequence,
                    fallback: "Open LocalWrap to review this issue.",
                    maximumBytes: 180
                ),
                projectID: projectID(from: issue.scope),
                attentionIssueID: issue.id,
                reviewTarget: issue.navigationTarget
            )
        }
        let representedRuntimeProjects = Set(boundedIssues.compactMap { issue -> String? in
            guard issue.sources.contains(.runtime) else { return nil }
            return projectID(from: issue.scope)
        })
        let representedConfigurationFailures = Set(boundedIssues.compactMap {
            representedConfigurationFailure(from: $0)
        })

        for project in projects {
            let runtime = runtimes[project.id] ?? RuntimeSnapshot()
            if isFailure(runtime), !representedRuntimeProjects.contains(project.id) {
                items.append(MenuCommandCenterItem(
                    id: "runtime-failure:\(project.id)",
                    kind: .runtimeFailure,
                    title: Self.menuText(
                        project.name,
                        fallback: "Unnamed Project",
                        maximumBytes: 80
                    ),
                    contextLabel: "Runtime",
                    statusLabel: runtimeFailureStatusLabel(runtime),
                    detailLabel: runtimeFailureDetail(runtime),
                    projectID: project.id,
                    attentionIssueID: nil,
                    reviewTarget: .project(projectID: project.id, surface: .runtime)
                ))
            }

            let policy = matchingPolicy(for: project.id, in: policies)
            if let field = policy.configuration.firstFailureField,
               !representedConfigurationFailures.contains(
                    ConfigurationFailureKey(projectID: project.id, field: field)
               ) {
                items.append(MenuCommandCenterItem(
                    id: "configuration:\(project.id):\(field.rawValue)",
                    kind: .configurationIssue,
                    title: Self.menuText(
                        project.name,
                        fallback: "Unnamed Project",
                        maximumBytes: 80
                    ),
                    contextLabel: "Configuration",
                    statusLabel: "Blocked — not ready to start",
                    detailLabel: quickActions[project.id]?.start.disabledReason,
                    projectID: project.id,
                    attentionIssueID: nil,
                    reviewTarget: .project(
                        projectID: project.id,
                        surface: .field(field)
                    )
                ))
            }
        }
        return items.sorted(by: attentionItemOrder)
    }

    private func representedConfigurationFailure(
        from issue: AttentionIssue
    ) -> ConfigurationFailureKey? {
        guard issue.sources.contains(.projectDoctor),
              case .project(let scopeProjectID, _) = issue.scope,
              case .project(let targetProjectID, let surface) = issue.navigationTarget,
              scopeProjectID == targetProjectID else { return nil }

        let field: ProjectField?
        switch surface {
        case .field(let value):
            field = value
        case .doctor(let check, _):
            field = projectField(for: check)
        case .runtime, .preview:
            field = nil
        }
        return field.map { ConfigurationFailureKey(projectID: scopeProjectID, field: $0) }
    }

    private func projectField(for check: DoctorCheckID) -> ProjectField? {
        switch check {
        case .directory: .cwd
        case .command: .command
        case .dependencies: .dependencies
        case .port: .port
        case .url: .url
        case .process, .readiness: nil
        }
    }

    private func attentionItemOrder(
        _ lhs: MenuCommandCenterItem,
        _ rhs: MenuCommandCenterItem
    ) -> Bool {
        let leftFailure = lhs.statusLabel.hasPrefix("Failure")
            || lhs.statusLabel.hasPrefix("Blocked")
        let rightFailure = rhs.statusLabel.hasPrefix("Failure")
            || rhs.statusLabel.hasPrefix("Blocked")
        if leftFailure != rightFailure { return leftFailure }
        return itemOrder(lhs, rhs)
    }

    private func projectQuickActions(
        project: Project,
        runtime: RuntimeSnapshot,
        policy: MenuProjectValidatedPolicy,
        hasAttention: Bool,
        startMutationBlockReason: String?,
        stopMutationBlockReason: String?
    ) -> MenuProjectQuickActions {
        let start: MenuActionCapability
        if let startMutationBlockReason {
            start = .disabled(startMutationBlockReason)
        } else if runtime.status.isActive {
            start = .disabled("Project is already running.")
        } else if runtime.ownership != .none {
            start = .disabled("Runtime ownership must be reconciled first.")
        } else if policy.configuration == .pending {
            start = .disabled("Project validation must finish first.")
        } else if !policy.configuration.isValid {
            start = .disabled("Project configuration needs review.")
        } else {
            start = .enabled
        }

        let stop: MenuActionCapability
        if let stopMutationBlockReason {
            stop = .disabled(stopMutationBlockReason)
        } else if runtime.status == .stopping {
            stop = .disabled("Project is already stopping.")
        } else if !runtime.status.isActive {
            stop = .disabled("Project is not running.")
        } else if !signalPolicyMatchesRuntime(policy.signalling, runtime: runtime) {
            stop = .disabled(
                policy.signalling.disabledReason ?? "Runtime ownership is not verified."
            )
        } else {
            stop = .enabled
        }

        let restart: MenuActionCapability
        if let startMutationBlockReason {
            restart = .disabled(startMutationBlockReason)
        } else if !stop.isEnabled {
            restart = .disabled(stop.disabledReason ?? "Project cannot be stopped safely.")
        } else if policy.configuration == .pending {
            restart = .disabled("Project validation must finish first.")
        } else if !policy.configuration.isValid {
            restart = .disabled("Project configuration needs review before restart.")
        } else {
            restart = .enabled
        }

        let open: MenuActionCapability
        if runtime.status != .ready {
            open = .disabled("Project is not ready.")
        } else if !policy.canOpenValidatedLocalURL {
            open = .disabled("Project URL is not a safe local URL.")
        } else {
            open = .enabled
        }

        let review = hasAttention || isFailure(runtime) || policy.configuration.requiresReview
            ? MenuActionCapability.enabled
            : .disabled("Project has no issues requiring review.")
        return MenuProjectQuickActions(
            projectID: project.id,
            start: start,
            stop: stop,
            restart: restart,
            open: open,
            review: review
        )
    }

    private func signalPolicyMatchesRuntime(
        _ capability: MenuRuntimeSignallingCapability,
        runtime: RuntimeSnapshot
    ) -> Bool {
        guard case .verified(let policyRunID) = capability,
              case .verified(let runtimeRunID) = runtime.ownership,
              policyRunID == runtimeRunID,
              runtime.runID == runtimeRunID else { return false }
        return true
    }

    private func workspaceQuickActions(
        projects: [Project],
        projectIDs: Set<String>,
        runtimes: [String: RuntimeSnapshot],
        workspace: WorkspaceState,
        projectActions: [String: MenuProjectQuickActions],
        workspacePolicies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy],
        startMutationBlockReason: String?,
        stopMutationBlockReason: String?
    ) -> MenuWorkspaceQuickActions {
        let allIDs = projects.map(\.id)
        let activeIDs = projects.filter {
            (runtimes[$0.id] ?? RuntimeSnapshot()).status.isActive
        }.map(\.id)
        let readyIDs = projects.filter {
            (runtimes[$0.id] ?? RuntimeSnapshot()).status == .ready
                && projectActions[$0.id]?.open.isEnabled == true
        }.map(\.id)
        let requestedResumeIDs = uniqueIDs(workspace.lastRunningProjectIds)
        let knownResumeIDs = requestedResumeIDs.filter { projectIDs.contains($0) }
        let resumeHasUnknownProject = knownResumeIDs.count != requestedResumeIDs.count

        let resume: MenuActionCapability
        if let startMutationBlockReason {
            resume = .disabled(startMutationBlockReason)
        } else if requestedResumeIDs.isEmpty {
            resume = .disabled("No previous workspace is saved.")
        } else if resumeHasUnknownProject {
            resume = .disabled("The previous workspace references a missing project.")
        } else if !activeIDs.isEmpty {
            resume = .disabled("Stop the current workspace before resuming another one.")
        } else if let reason = workspacePolicyBlockReason(
            target: .lastRunning,
            projectIDs: knownResumeIDs,
            policies: workspacePolicies
        ) {
            resume = .disabled(reason)
        } else if knownResumeIDs.contains(where: { projectActions[$0]?.start.isEnabled != true }) {
            resume = .disabled("A project in the previous workspace is not safe to start.")
        } else {
            resume = .enabled
        }

        let startAll: MenuActionCapability
        if let startMutationBlockReason {
            startAll = .disabled(startMutationBlockReason)
        } else if allIDs.isEmpty {
            startAll = .disabled("No projects are saved.")
        } else if !activeIDs.isEmpty {
            startAll = .disabled("A workspace is already running.")
        } else if let reason = workspacePolicyBlockReason(
            target: .allProjects,
            projectIDs: allIDs,
            policies: workspacePolicies
        ) {
            startAll = .disabled(reason)
        } else if allIDs.contains(where: { projectActions[$0]?.start.isEnabled != true }) {
            startAll = .disabled("One or more projects are not safe to start.")
        } else {
            startAll = .enabled
        }

        let stopAll: MenuActionCapability
        if let stopMutationBlockReason {
            stopAll = .disabled(stopMutationBlockReason)
        } else if activeIDs.isEmpty {
            stopAll = .disabled("No projects are running.")
        } else if activeIDs.contains(where: { projectActions[$0]?.stop.isEnabled != true }) {
            stopAll = .disabled("One or more running projects cannot be stopped safely.")
        } else {
            stopAll = .enabled
        }

        let openReady = readyIDs.isEmpty
            ? MenuActionCapability.disabled("No projects are ready to open.")
            : .enabled
        let savedWorkspaces = savedWorkspaceActions(
            workspace.savedWorkspaces,
            knownProjectIDs: projectIDs,
            activeProjectIDs: activeIDs,
            projectActions: projectActions,
            policies: workspacePolicies,
            startMutationBlockReason: startMutationBlockReason
        )
        return MenuWorkspaceQuickActions(
            resume: resume,
            resumeProjectIDs: knownResumeIDs,
            startAll: startAll,
            startAllProjectIDs: allIDs,
            stopAll: stopAll,
            stopAllProjectIDs: activeIDs,
            openReadyApps: openReady,
            readyProjectIDs: readyIDs,
            savedWorkspaces: Array(
                savedWorkspaces.prefix(Self.maximumSavedWorkspaceQuickActions)
            ),
            savedWorkspaceTotalCount: workspace.savedWorkspaces.count
        )
    }

    private func savedWorkspaceActions(
        _ profiles: [WorkspaceProfile],
        knownProjectIDs: Set<String>,
        activeProjectIDs: [String],
        projectActions: [String: MenuProjectQuickActions],
        policies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy],
        startMutationBlockReason: String?
    ) -> [MenuSavedWorkspaceQuickAction] {
        let profiles = Self.profilesRequiringPolicy(profiles)

        return profiles.map { profile in
            let projectIDs = uniqueIDs(profile.projectIds)
            let target = WorkspaceTarget.profile(profile.id)
            let hasUnknownProject = projectIDs.contains { !knownProjectIDs.contains($0) }
            let capability: MenuActionCapability

            if let startMutationBlockReason {
                capability = .disabled(startMutationBlockReason)
            } else if !activeProjectIDs.isEmpty {
                capability = .disabled("Stop the current workspace before starting another one.")
            } else if projectIDs.isEmpty {
                capability = .disabled("The workspace has no projects.")
            } else if hasUnknownProject {
                capability = .disabled("The workspace references a missing project.")
            } else if let reason = workspacePolicyBlockReason(
                target: target,
                projectIDs: projectIDs,
                policies: policies
            ) {
                capability = .disabled(reason)
            } else if projectIDs.contains(where: { projectActions[$0]?.start.isEnabled != true }) {
                capability = .disabled("A project in this workspace is not safe to start.")
            } else {
                capability = .enabled
            }

            return MenuSavedWorkspaceQuickAction(
                profileID: profile.id,
                name: Self.menuText(
                    profile.name,
                    fallback: "Unnamed Workspace",
                    maximumBytes: 80
                ),
                projectIDs: projectIDs,
                start: capability
            )
        }
    }

    private static func workspaceProfileOrder(
        _ lhs: WorkspaceProfile,
        _ rhs: WorkspaceProfile
    ) -> Bool {
        let left = Self.menuText(
            lhs.name,
            fallback: "Unnamed Workspace",
            maximumBytes: 80
        ).lowercased()
        let right = Self.menuText(
            rhs.name,
            fallback: "Unnamed Workspace",
            maximumBytes: 80
        ).lowercased()
        return left == right ? lhs.id < rhs.id : left < right
    }

    private func workspacePolicyBlockReason(
        target: WorkspaceTarget,
        projectIDs: [String],
        policies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy]
    ) -> String? {
        guard let policy = policies[target],
              policy.target == target,
              Set(policy.projectIDs) == Set(projectIDs) else {
            return MenuWorkspaceValidationBlockReason.validationPending.label
        }
        if case .blocked(let reason) = policy.validation { return reason.label }
        return nil
    }

    private func primaryAction(
        attentionItems: [MenuCommandCenterItem],
        projects: [Project],
        runtimes: [String: RuntimeSnapshot],
        workspaceActions: MenuWorkspaceQuickActions
    ) -> MenuCommandCenterPrimaryAction? {
        let firstFailure = attentionItems.first { item in
            item.kind == .runtimeFailure
                || item.kind == .configurationIssue
                || (item.kind == .attentionIssue
                    && item.statusLabel.hasPrefix("Failure"))
        }
        let failedProjectIDs = projects.filter {
            isFailure(runtimes[$0.id] ?? RuntimeSnapshot())
        }.map(\.id)
        if let firstFailure {
            return MenuCommandCenterPrimaryAction(
                kind: .reviewFailure,
                projectIDs: firstFailure.projectID.map { [$0] } ?? failedProjectIDs,
                workspaceTarget: nil,
                attentionIssueID: firstFailure.attentionIssueID,
                reviewTarget: firstFailure.reviewTarget
            )
        }
        if workspaceActions.openReadyApps.isEnabled {
            return MenuCommandCenterPrimaryAction(
                kind: .openReadyApps,
                projectIDs: workspaceActions.readyProjectIDs,
                workspaceTarget: nil,
                attentionIssueID: nil,
                reviewTarget: nil
            )
        }
        if workspaceActions.resume.isEnabled {
            return MenuCommandCenterPrimaryAction(
                kind: .resume,
                projectIDs: workspaceActions.resumeProjectIDs,
                workspaceTarget: .lastRunning,
                attentionIssueID: nil,
                reviewTarget: nil
            )
        }
        return nil
    }

    private func runtimeStatusLabel(_ runtime: RuntimeSnapshot) -> String {
        switch runtime.status {
        case .stopped: "Stopped — ready to start"
        case .starting: "Starting — waiting for the app"
        case .ready: "Ready — app is responding"
        case .runningUnresponsive: "Running — app is not responding"
        case .stopping: "Stopping — cleanup in progress"
        case .failed: "Failed — review required"
        }
    }

    private func runtimeFailureStatusLabel(_ runtime: RuntimeSnapshot) -> String {
        if runtime.ownership.requiresOwnershipReview {
            return "Failure — ownership needs review"
        }
        return switch runtime.terminalReason {
        case .ownershipConflict, .ownershipUnverifiable: "Failure — ownership needs review"
        case .cleanupFailure: "Failure — cleanup needs review"
        case .readinessTimeout: "Failure — app did not become ready"
        case .unexpectedExit: "Failure — app exited unexpectedly"
        case .doctorBlocked: "Failure — configuration blocked start"
        case .launchFailure: "Failure — app did not start"
        case .intentionalStop, .none: "Failure — review required"
        }
    }

    private func runtimeDetail(_ runtime: RuntimeSnapshot) -> String? {
        switch runtime.status {
        case .runningUnresponsive:
            "The process is running, but readiness has not been confirmed."
        case .failed:
            runtimeFailureDetail(runtime)
        case .stopped, .starting, .ready, .stopping:
            nil
        }
    }

    private func runtimeFailureDetail(_ runtime: RuntimeSnapshot) -> String {
        if runtime.ownership.requiresOwnershipReview {
            return "LocalWrap cannot control this process until ownership is reconciled."
        }
        return switch runtime.terminalReason {
        case .readinessTimeout:
            "The process started, but the local app did not become ready."
        case .cleanupFailure:
            "LocalWrap could not confirm that the process group stopped."
        case .unexpectedExit:
            "The app exited unexpectedly."
        case .doctorBlocked:
            "Project configuration prevented the app from starting."
        case .launchFailure:
            "The app could not be launched."
        case .ownershipConflict, .ownershipUnverifiable:
            "LocalWrap cannot control this process until ownership is reconciled."
        case .intentionalStop, .none:
            "The last run needs review."
        }
    }

    private func isFailure(_ runtime: RuntimeSnapshot) -> Bool {
        if runtime.status == .failed || runtime.ownership.requiresOwnershipReview { return true }
        switch runtime.terminalReason {
        case .launchFailure, .doctorBlocked, .readinessTimeout, .cleanupFailure,
             .unexpectedExit, .ownershipConflict, .ownershipUnverifiable:
            return true
        case .intentionalStop, .none:
            return false
        }
    }

    private func projectID(from scope: AttentionScope) -> String? {
        if case .project(let id, _) = scope { return id }
        return nil
    }

    private func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func startMutationBlockReason(_ input: MenuCommandCenterInput) -> String? {
        if !input.permitsRuntimeMutation {
            return "Runtime reconciliation must finish first."
        }
        if input.workspaceOperationInProgress {
            return "A workspace operation is already in progress."
        }
        return nil
    }

    private func stopMutationBlockReason(_ input: MenuCommandCenterInput) -> String? {
        guard !input.permitsRuntimeMutation else { return nil }
        return "Runtime reconciliation must finish first."
    }

    private func statusLabel(groups: [MenuCommandCenterGroup]) -> String {
        groups.filter { $0.totalCount > 0 }.map { group in
            "\(group.count) \(group.title.lowercased())"
        }.joined(separator: ", ")
    }

    private static func menuText(
        _ value: String,
        fallback: String,
        maximumBytes: Int
    ) -> String {
        let sanitized = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format {
                return " "
            }
            return String(scalar)
        }.joined()
        let collapsed = sanitized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let source = collapsed.isEmpty ? fallback : collapsed

        var result = ""
        var byteCount = 0
        for character in source {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= maximumBytes else { break }
            result.append(character)
            byteCount += bytes
        }
        return result.isEmpty ? fallback : result
    }
}

private struct ConfigurationFailureKey: Hashable {
    let projectID: String
    let field: ProjectField
}
