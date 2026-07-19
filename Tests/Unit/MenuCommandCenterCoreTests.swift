import XCTest
@testable import LocalWrapMac

final class MenuCommandCenterCoreTests: XCTestCase {
    private let service = MenuCommandCenterService()

    func testCompactEmptyStateAlwaysKeepsShowInLocalWrapAvailable() {
        let snapshot = service.snapshot(MenuCommandCenterInput(projects: []))

        XCTAssertEqual(snapshot.statusLabel, "No projects")
        XCTAssertEqual(snapshot.emptyState?.title, "No projects yet")
        XCTAssertTrue(snapshot.visibleGroups.isEmpty)
        XCTAssertTrue(snapshot.showInLocalWrap.isEnabled)
    }

    func testActiveSnapshotWithNoVerifiedOwnedRunNeverExposesStopOrRestart() throws {
        let project = project("app", "App")
        var runtime = RuntimeSnapshot()
        runtime.status = .runningUnresponsive
        runtime.runID = "run-1"
        runtime.ownership = .none
        let policy = MenuProjectValidatedPolicy(
            projectID: project.id,
            configuration: .valid,
            canOpenValidatedLocalURL: true,
            signalling: .verified(runID: "run-1")
        )

        let snapshot = service.snapshot(MenuCommandCenterInput(
            projects: [project],
            runtimes: [project.id: runtime],
            policies: [project.id: policy]
        ))
        let actions = try XCTUnwrap(snapshot.quickActions(for: project.id))

        XCTAssertFalse(actions.stop.isEnabled)
        XCTAssertFalse(actions.restart.isEnabled)
    }

    func testRetainedRuntimeFailureRemainsPrimaryButDoesNotDeadlockSafeRetry() throws {
        let project = project("app", "App")
        var runtime = RuntimeSnapshot()
        runtime.status = .stopped
        runtime.terminalReason = .readinessTimeout
        runtime.ownership = .none
        let issue = attentionIssue(
            id: "old-readiness-failure",
            severity: .blocker,
            source: .runtime,
            scope: .project(id: project.id, name: project.name),
            target: .project(projectID: project.id, surface: .runtime)
        )

        let snapshot = service.snapshot(MenuCommandCenterInput(
            projects: [project],
            runtimes: [project.id: runtime],
            policies: [project.id: safePolicy(project.id)],
            attention: attention([issue])
        ))

        XCTAssertTrue(try XCTUnwrap(snapshot.quickActions(for: project.id)).start.isEnabled)
        XCTAssertEqual(snapshot.primaryAction?.kind, .reviewFailure)
        XCTAssertEqual(snapshot.primaryAction?.attentionIssueID, issue.id)
    }

    func testConfigurationSuppressionIsExactAndNameRoutesToNameField() throws {
        let project = project("app", "")
        let runtimeIssue = attentionIssue(
            id: "runtime",
            severity: .blocker,
            source: .runtime,
            scope: .project(id: project.id, name: "App"),
            target: .project(projectID: project.id, surface: .runtime)
        )
        let invalidPolicy = MenuProjectValidatedPolicy(
            projectID: project.id,
            configuration: .invalid(firstFailureField: .name),
            canOpenValidatedLocalURL: true,
            signalling: .unavailable(.noOwnedProcess)
        )

        let withUnrelatedIssue = service.snapshot(MenuCommandCenterInput(
            projects: [project],
            policies: [project.id: invalidPolicy],
            attention: attention([runtimeIssue])
        ))
        let synthetic = try XCTUnwrap(
            withUnrelatedIssue.group(.attention).items.first { $0.kind == .configurationIssue }
        )
        XCTAssertEqual(
            synthetic.reviewTarget,
            .project(projectID: project.id, surface: .field(.name))
        )

        let exactIssue = attentionIssue(
            id: "name",
            severity: .blocker,
            source: .projectDoctor,
            scope: .project(id: project.id, name: "App"),
            target: .project(projectID: project.id, surface: .field(.name))
        )
        let exact = service.snapshot(MenuCommandCenterInput(
            projects: [project],
            policies: [project.id: invalidPolicy],
            attention: attention([exactIssue])
        ))
        XCTAssertFalse(exact.group(.attention).items.contains { $0.kind == .configurationIssue })
    }

    func testSavedWorkspacesUseTheirOwnCanonicalizedPrecomputedPolicies() throws {
        let alpha = project("alpha", "Alpha")
        let beta = project("beta", "Beta")
        let blocked = profile("blocked", "Blocked", [alpha.id, beta.id])
        let ready = profile("ready", "Ready", [beta.id, alpha.id])
        let workspace = WorkspaceState(
            lastRunningProjectIds: [],
            savedWorkspaces: [ready, blocked],
            updatedAt: nil
        )
        let policies = [alpha.id: safePolicy(alpha.id), beta.id: safePolicy(beta.id)]
        let workspacePolicies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy] = [
            .profile(blocked.id): MenuWorkspaceValidatedPolicy(
                target: .profile(blocked.id),
                projectIDs: [beta.id, alpha.id],
                validation: .blocked(.dependencies)
            ),
            .profile(ready.id): MenuWorkspaceValidatedPolicy(
                target: .profile(ready.id),
                projectIDs: [alpha.id, beta.id],
                validation: .ready
            ),
        ]

        let snapshot = service.snapshot(MenuCommandCenterInput(
            projects: [beta, alpha],
            policies: policies,
            workspacePolicies: workspacePolicies,
            workspace: workspace
        ))
        let blockedAction = try XCTUnwrap(
            snapshot.workspaceQuickActions.savedWorkspaces.first { $0.profileID == blocked.id }
        )
        let readyAction = try XCTUnwrap(
            snapshot.workspaceQuickActions.savedWorkspaces.first { $0.profileID == ready.id }
        )

        XCTAssertFalse(blockedAction.start.isEnabled)
        XCTAssertEqual(blockedAction.start.disabledReason, "Workspace dependencies need review.")
        XCTAssertTrue(readyAction.start.isEnabled)
    }

    func testSnapshotOrderingIsStableAndMenuCollectionsAreBounded() {
        let small = (0..<20).map { project("p\($0)", "Project \(19 - $0)") }
        let policies = Dictionary(uniqueKeysWithValues: small.map { ($0.id, safePolicy($0.id)) })
        let first = service.snapshot(MenuCommandCenterInput(projects: small, policies: policies))
        let second = service.snapshot(MenuCommandCenterInput(
            projects: Array(small.reversed()),
            policies: policies
        ))
        XCTAssertEqual(first, second)

        let large = (0..<140).map { project("large-\($0)", "Project \($0)") }
        let largePolicies = Dictionary(
            uniqueKeysWithValues: large.map { ($0.id, safePolicy($0.id)) }
        )
        let profiles = (0..<20).map { profile("w\($0)", "Workspace \($0)", [large[0].id]) }
        let workspacePolicies = Dictionary(uniqueKeysWithValues: profiles.map {
            let target = WorkspaceTarget.profile($0.id)
            return (target, MenuWorkspaceValidatedPolicy(
                target: target,
                projectIDs: $0.projectIds,
                validation: .ready
            ))
        })
        let bounded = service.snapshot(MenuCommandCenterInput(
            projects: large,
            policies: largePolicies,
            workspacePolicies: workspacePolicies,
            workspace: WorkspaceState(
                lastRunningProjectIds: [],
                savedWorkspaces: profiles,
                updatedAt: nil
            )
        ))

        XCTAssertLessThanOrEqual(bounded.projectQuickActions.count, 32)
        XCTAssertEqual(bounded.projectQuickActionTotalCount, 140)
        XCTAssertTrue(bounded.groups.allSatisfy { $0.items.count <= 8 })
        XCTAssertLessThanOrEqual(bounded.workspaceQuickActions.savedWorkspaces.count, 6)
        XCTAssertEqual(bounded.workspaceQuickActions.savedWorkspaceTotalCount, 20)
        XCTAssertTrue(bounded.hasOverflow)
        XCTAssertTrue(bounded.showInLocalWrap.isEnabled)
    }

    func testEveryVisibleProjectKeepsItsFixedActionsAcrossAllFourGroups() {
        let projects = (0..<64).map { index -> Project in
            let prefix: String
            switch index {
            case 0..<40: prefix = "A Stopped"
            case 40..<48: prefix = "X Ready"
            case 48..<56: prefix = "Y Running"
            default: prefix = "Z Failed"
            }
            return project("p\(index)", "\(prefix) \(index)")
        }
        let policies = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.id, safePolicy($0.id)) }
        )
        var runtimes: [String: RuntimeSnapshot] = [:]
        for (index, project) in projects.enumerated() {
            var runtime = RuntimeSnapshot()
            switch index {
            case 40..<48:
                runtime.status = .ready
            case 48..<56:
                runtime.status = .runningUnresponsive
            case 56...:
                runtime.status = .failed
                runtime.terminalReason = .launchFailure
            default:
                runtime.status = .stopped
            }
            runtimes[project.id] = runtime
        }

        let snapshot = service.snapshot(MenuCommandCenterInput(
            projects: projects,
            runtimes: runtimes,
            policies: policies
        ))
        let visibleProjectIDs = Set(snapshot.visibleGroups.flatMap(\.items).compactMap(\.projectID))

        XCTAssertEqual(visibleProjectIDs.count, 32)
        XCTAssertTrue(visibleProjectIDs.allSatisfy {
            snapshot.quickActions(for: $0) != nil
        })
    }

    func testMenuFacingNamesStripFormatControlsAndAreUTF8Bounded() throws {
        let malicious = "\u{202E}Project\n" + String(repeating: "é", count: 100)
        let project = project("app", malicious)
        let snapshot = service.snapshot(MenuCommandCenterInput(
            projects: [project],
            policies: [project.id: safePolicy(project.id)]
        ))
        let title = try XCTUnwrap(snapshot.group(.readyToStart).items.first?.title)

        XCTAssertLessThanOrEqual(title.utf8.count, 80)
        XCTAssertFalse(title.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || $0.properties.generalCategory == .format
        })
    }

    private func project(_ id: String, _ name: String) -> Project {
        Project(
            id: id,
            name: name,
            cwd: "/tmp/\(id)",
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000",
            createdAt: "2026-07-19T10:00:00Z",
            updatedAt: "2026-07-19T10:00:00Z"
        )
    }

    private func safePolicy(_ projectID: String) -> MenuProjectValidatedPolicy {
        MenuProjectValidatedPolicy(
            projectID: projectID,
            configuration: .valid,
            canOpenValidatedLocalURL: true,
            signalling: .unavailable(.noOwnedProcess)
        )
    }

    private func profile(_ id: String, _ name: String, _ projectIDs: [String]) -> WorkspaceProfile {
        WorkspaceProfile(
            id: id,
            name: name,
            projectIds: projectIDs,
            createdAt: nil,
            updatedAt: nil,
            lastStartedAt: nil,
            source: nil
        )
    }

    private func attention(_ issues: [AttentionIssue]) -> AttentionSnapshot {
        AttentionSnapshot(generatedAt: "2026-07-19T10:00:00Z", issues: issues, history: [])
    }

    private func attentionIssue(
        id: String,
        severity: AttentionSeverity,
        source: AttentionSource,
        scope: AttentionScope,
        target: AttentionNavigationTarget
    ) -> AttentionIssue {
        AttentionIssue(
            id: id,
            severity: severity,
            sources: [source],
            scope: scope,
            title: "Review failure",
            consequence: "Review this issue in LocalWrap.",
            nextAction: AttentionNextAction(
                label: "Review",
                kind: .navigate,
                requiresConfirmation: false
            ),
            navigationTarget: target
        )
    }
}
