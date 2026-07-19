import Foundation
import XCTest
@testable import LocalWrapMac

final class AttentionServiceTests: XCTestCase {
    func testGlobalSnapshotIncludesDiagnosesAndOperationsFromEveryWorkspaceTarget() async {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let profileDiagnosis = workspaceDiagnosis(
            check: .environment,
            severity: .warning,
            message: "SENTINEL_SECRET_PROFILE",
            target: .profile("profile-one"),
            projectID: "project-1",
            projectName: "Web"
        )
        let allProjectsDiagnosis = workspaceDiagnosis(
            check: .ports,
            severity: .blocker,
            message: "SENTINEL_SECRET_ALL",
            target: .allProjects,
            projectID: "project-2",
            projectName: "Worker"
        )
        let retainedOperation = WorkspaceOperationSummary(
            results: [operationResult(
                projectID: "project-3",
                name: "Jobs",
                status: .skipped,
                reason: "dependency-not-ready",
                message: "SENTINEL_SECRET_OPERATION"
            )],
            target: .lastRunning
        )

        let snapshot = await service.update(AttentionInput(
            projects: [
                project(),
                project(id: "project-2", name: "Worker"),
                project(id: "project-3", name: "Jobs"),
            ],
            workspaceDiagnoses: [profileDiagnosis, allProjectsDiagnosis],
            workspaceOperations: [retainedOperation]
        ))

        XCTAssertEqual(Set(snapshot.issues.compactMap(projectID)), [
            "project-1", "project-2", "project-3",
        ])
        XCTAssertEqual(snapshot.blockerCount, 1)
        XCTAssertEqual(snapshot.warningCount, 2)
        XCTAssertFalse(String(reflecting: snapshot).contains("SENTINEL_SECRET"))
    }

    func testWorkspaceDoctorBlockedOperationMergesIntoDeterministicCausalIssue() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        var projectDiagnosis = ProjectDiagnosis.notChecked()
        projectDiagnosis.status = .failed
        projectDiagnosis.setCheck(.port, status: .fail, message: "SENTINEL_PROJECT")
        let workspace = workspaceDiagnosis(
            check: .ports,
            severity: .blocker,
            message: "SENTINEL_WORKSPACE"
        )
        let operation = WorkspaceOperationSummary(results: [operationResult(
            status: .blocked,
            reason: "workspace-doctor-blocked",
            message: "SENTINEL_OPERATION"
        )])

        let snapshot = await service.update(AttentionInput(
            projects: [project()],
            projectDiagnoses: ["project-1": projectDiagnosis],
            workspaceDiagnoses: [workspace],
            workspaceOperations: [operation]
        ))
        let issue = try XCTUnwrap(snapshot.issues.first)

        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(
            issue.sources,
            [.projectDoctor, .workspaceDoctor, .workspaceOperation]
        )
        XCTAssertEqual(issue.title, "Port needs attention")
        XCTAssertEqual(
            issue.navigationTarget,
            .project(projectID: "project-1", surface: .field(.port))
        )
    }

    func testDoctorBlockedRuntimeMergesIntoTheCausalProjectDoctorIssue() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        var diagnosis = ProjectDiagnosis.notChecked()
        diagnosis.status = .failed
        diagnosis.setCheck(.command, status: .fail, message: "SENTINEL_SECRET_COMMAND")
        let runtime = RuntimeSnapshot(
            status: .failed,
            terminalReason: .doctorBlocked,
            error: "SENTINEL_SECRET_RUNTIME",
            diagnosis: diagnosis
        )

        let snapshot = await service.update(AttentionInput(
            projects: [project()],
            runtimes: ["project-1": runtime],
            projectDiagnoses: ["project-1": diagnosis]
        ))
        let issue = try XCTUnwrap(snapshot.issues.first)

        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(issue.sources, [.projectDoctor, .runtime])
        XCTAssertEqual(issue.title, "Command needs attention")
        XCTAssertEqual(
            issue.navigationTarget,
            .project(projectID: "project-1", surface: .field(.command))
        )
        XCTAssertFalse(String(reflecting: snapshot).contains("SENTINEL_SECRET"))
    }

    func testStoredPresentationFieldsAreControlFreeByteBoundedAndSecretSafe() async throws {
        let service = AttentionService(now: {
            "2026-07-19T00:00:00Z\nSENTINEL_SECRET_TIMESTAMP"
        })
        let hostileName = String(repeating: "é", count: 1_000)
            + "\n\u{0000}SENTINEL_SECRET_PROJECT"
        var preview = PreviewState()
        preview.open(try XCTUnwrap(URL(string: "http://localhost:3000/?token=SENTINEL")))
        preview.markFailed("Authorization: Bearer SENTINEL_SECRET_LOG\u{0000}\n")

        let snapshot = await service.update(AttentionInput(
            projects: [project(name: hostileName)],
            previews: ["project-1": preview]
        ))
        let issue = try XCTUnwrap(snapshot.issues.first)
        let presentation = [
            issue.scope.displayName,
            issue.title,
            issue.consequence,
            issue.nextAction.label,
        ].joined(separator: "|")

        XCTAssertEqual(snapshot.generatedAt, "")
        XCTAssertLessThanOrEqual(issue.scope.displayName.utf8.count, AttentionIssue.maximumScopeNameBytes)
        XCTAssertLessThanOrEqual(issue.title.utf8.count, AttentionIssue.maximumTitleBytes)
        XCTAssertLessThanOrEqual(issue.consequence.utf8.count, AttentionIssue.maximumConsequenceBytes)
        XCTAssertLessThanOrEqual(issue.nextAction.label.utf8.count, AttentionIssue.maximumActionLabelBytes)
        XCTAssertFalse(presentation.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        })
        XCTAssertFalse(String(reflecting: snapshot).contains("SENTINEL_SECRET"))
        XCTAssertTrue(snapshot.history.allSatisfy { $0.id.hasPrefix("attention:") })
    }

    func testIssueOrderingAndCausalIdentityDoNotDependOnInputOrder() async {
        let firstService = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let secondService = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let diagnoses = [
            workspaceDiagnosis(
                check: .environment,
                severity: .warning,
                message: "one",
                target: .profile("z"),
                projectID: "project-1",
                projectName: "Zulu"
            ),
            workspaceDiagnosis(
                check: .ports,
                severity: .blocker,
                message: "two",
                target: .profile("a"),
                projectID: "project-2",
                projectName: "Alpha"
            ),
        ]
        let operations = [
            WorkspaceOperationSummary(results: [operationResult(
                projectID: "project-1",
                name: "Zulu",
                status: .blocked,
                reason: "workspace-doctor-blocked",
                message: "one"
            )], target: .profile("z")),
            WorkspaceOperationSummary(results: [operationResult(
                projectID: "project-2",
                name: "Alpha",
                status: .blocked,
                reason: "workspace-doctor-blocked",
                message: "two"
            )], target: .profile("a")),
        ]
        let projects = [project(name: "Zulu"), project(id: "project-2", name: "Alpha")]

        let first = await firstService.update(AttentionInput(
            projects: projects,
            workspaceDiagnoses: diagnoses,
            workspaceOperations: operations
        ))
        let second = await secondService.update(AttentionInput(
            projects: Array(projects.reversed()),
            workspaceDiagnoses: Array(diagnoses.reversed()),
            workspaceOperations: Array(operations.reversed())
        ))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.issues.map(\.severity), [.blocker, .blocker])
        XCTAssertEqual(first.issues.map(\.scope.displayName), ["Alpha", "Zulu"])
    }

    func testLatestDiagnosisForTargetCanResolveOlderEvidenceWhileHistoryRemains() async {
        let timestamps = TimestampSequence()
        let service = AttentionService(now: { timestamps.next() })
        let older = workspaceDiagnosis(
            check: .ports,
            severity: .blocker,
            message: "old",
            updatedAt: "2026-07-19T00:00:01Z"
        )
        let first = await service.update(AttentionInput(
            projects: [project()],
            workspaceDiagnoses: [older]
        ))
        let newer = healthyWorkspaceDiagnosis(updatedAt: "2026-07-19T00:00:02Z")
        let second = await service.update(AttentionInput(
            projects: [project()],
            workspaceDiagnoses: [older, newer]
        ))

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.issues.isEmpty)
        XCTAssertEqual(second.history.first?.event, .resolved)
        XCTAssertTrue(second.history.contains { $0.event == .opened })
    }

    func testActiveIssueStorageIsBoundedBeforeItBecomesHistory() async {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        var projects: [Project] = []
        var previews: [String: PreviewState] = [:]
        for index in 0..<600 {
            let id = String(format: "project-%03d", index)
            projects.append(project(id: id, name: "Project \(index)"))
            var preview = PreviewState()
            preview.open(URL(string: "http://localhost:3000")!)
            preview.markFailed("SENTINEL_SECRET_\(index)")
            previews[id] = preview
        }

        let snapshot = await service.update(AttentionInput(
            projects: projects,
            previews: previews
        ))

        XCTAssertEqual(snapshot.issues.count, AttentionService.maximumProjects)
        XCTAssertLessThanOrEqual(snapshot.issues.count, AttentionService.maximumActiveIssues)
        XCTAssertEqual(snapshot.history.count, AttentionService.maximumHistoryEntries)
        XCTAssertFalse(String(reflecting: snapshot).contains("SENTINEL_SECRET"))
    }

    func testProjectDoctorIssueHasStableIDAndConfirmedMutatingFix() async {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        var firstDiagnosis = ProjectDiagnosis.notChecked(now: "one")
        firstDiagnosis.status = .attention
        firstDiagnosis.setCheck(
            .port,
            status: .warn,
            message: "Port message with SECRET_VALUE_ONE",
            actions: [.findFreePort]
        )
        let first = await service.update(AttentionInput(
            projects: [project(name: "Secret project name")],
            projectDiagnoses: ["project-1": firstDiagnosis]
        ))
        let firstIssue = try? XCTUnwrap(first.issues.first)

        var changedDiagnosis = firstDiagnosis
        changedDiagnosis.setCheck(
            .port,
            status: .warn,
            message: "Entirely different SECRET_VALUE_TWO",
            actions: [.findFreePort]
        )
        let changed = await service.update(AttentionInput(
            projects: [project(name: "Renamed project")],
            projectDiagnoses: ["project-1": changedDiagnosis]
        ))
        let changedIssue = try? XCTUnwrap(changed.issues.first)

        XCTAssertEqual(firstIssue?.id, changedIssue?.id)
        XCTAssertFalse(firstIssue?.id.contains("project-1") == true)
        XCTAssertEqual(firstIssue?.severity, .warning)
        XCTAssertEqual(firstIssue?.nextAction.kind, .doctor(.findFreePort))
        XCTAssertEqual(firstIssue?.nextAction.requiresConfirmation, true)
        XCTAssertEqual(
            firstIssue?.navigationTarget,
            .project(
                projectID: "project-1",
                surface: .doctor(check: .port, suggestedAction: .findFreePort)
            )
        )
        XCTAssertEqual(changed.history.count, 1, "Presentation copy changes must not churn history")
    }

    func testReadinessSymptomsDeduplicateAcrossDoctorRuntimeAndWorkspaceOperation() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        var diagnosis = ProjectDiagnosis.notChecked()
        diagnosis.status = .attention
        diagnosis.setCheck(.readiness, status: .warn, message: "Not ready")
        let runtime = RuntimeSnapshot(
            status: .runningUnresponsive,
            terminalReason: .readinessTimeout,
            diagnosis: diagnosis
        )
        let operation = WorkspaceOperationSummary(results: [
            operationResult(status: .failed, reason: "not-ready", message: "SECRET runtime detail")
        ])

        let snapshot = await service.update(AttentionInput(
            projects: [project()],
            runtimes: ["project-1": runtime],
            projectDiagnoses: ["project-1": diagnosis],
            workspaceOperation: operation
        ))
        let issue = try XCTUnwrap(snapshot.issues.first)

        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(issue.severity, .blocker)
        XCTAssertEqual(issue.sources, [.projectDoctor, .runtime, .workspaceOperation])
        XCTAssertEqual(issue.title, "Project did not become ready")
        XCTAssertEqual(
            issue.navigationTarget,
            .project(projectID: "project-1", surface: .runtime)
        )
    }

    func testWorkspaceDoctorAggregatesProjectIssueWithoutCopyingDiagnosticMessage() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let diagnosis = workspaceDiagnosis(
            check: .environment,
            severity: .warning,
            message: "Missing TOP_SECRET_KEY=actual-secret"
        )

        let snapshot = await service.update(AttentionInput(
            projects: [project(name: "API")],
            workspaceDiagnosis: diagnosis
        ))
        let issue = try XCTUnwrap(snapshot.issues.first)
        let rendered = [issue.title, issue.consequence, issue.nextAction.label].joined(separator: " ")

        XCTAssertEqual(issue.sources, [.workspaceDoctor])
        XCTAssertEqual(issue.scope, .project(id: "project-1", name: "API"))
        XCTAssertFalse(rendered.contains("TOP_SECRET"))
        XCTAssertEqual(
            issue.navigationTarget,
            .workspace(target: .allProjects, projectID: "project-1")
        )
    }

    func testRuntimeOwnershipAndReconciliationCollapseToOneFailClosedIssue() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let runtime = RuntimeSnapshot(
            status: .runningUnresponsive,
            runID: "run-secret",
            ownership: .unverifiable(runID: "run-secret", reason: .permissionDenied),
            terminalReason: .ownershipUnverifiable
        )
        let reconciliation = RuntimeReconciliationReport(
            items: [RuntimeReconciliationItem(
                runID: "run-secret",
                projectID: "project-1",
                classification: .unverifiable,
                message: "SECRET permission detail"
            )],
            ledgerError: nil
        )

        let snapshot = await service.update(AttentionInput(
            projects: [project()],
            runtimes: ["project-1": runtime],
            runtimeReconciliation: reconciliation
        ))
        let issue = try XCTUnwrap(snapshot.issues.first)

        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(issue.severity, .blocker)
        XCTAssertEqual(issue.nextAction.kind, .reconcileRuntime)
        XCTAssertTrue(issue.consequence.contains("will not signal"))
        XCTAssertFalse(String(reflecting: snapshot.history).contains("run-secret"))
        XCTAssertFalse(String(reflecting: snapshot.history).contains("SECRET"))
    }

    func testUnexpectedExitIdentityDoesNotDependOnExitCodeOrRawError() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let first = await service.update(AttentionInput(
            projects: [project()],
            runtimes: ["project-1": RuntimeSnapshot(
                status: .failed,
                terminalReason: .unexpectedExit(code: 1),
                error: "SECRET_ONE"
            )]
        ))
        let second = await service.update(AttentionInput(
            projects: [project()],
            runtimes: ["project-1": RuntimeSnapshot(
                status: .failed,
                terminalReason: .unexpectedExit(code: 137),
                error: "SECRET_TWO"
            )]
        ))

        XCTAssertEqual(try XCTUnwrap(first.issues.first).id, try XCTUnwrap(second.issues.first).id)
        XCTAssertFalse(String(reflecting: second).contains("SECRET"))
        XCTAssertFalse(String(reflecting: second).contains("137"))
    }

    func testWorkspaceBlockedAndDependencySkippedBecomeActionableIssues() async {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let operation = WorkspaceOperationSummary(results: [
            operationResult(
                projectID: "project-1",
                name: "Web",
                status: .blocked,
                reason: "workspace-doctor-blocked",
                message: "SECRET blocked reason"
            ),
            operationResult(
                projectID: "project-2",
                name: "Worker",
                status: .skipped,
                reason: "dependency-not-ready",
                message: "SECRET dependency name"
            )
        ])

        let snapshot = await service.update(AttentionInput(
            projects: [project(), project(id: "project-2", name: "Worker")],
            workspaceOperation: operation
        ))

        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.blockerCount, 1)
        XCTAssertEqual(snapshot.warningCount, 1)
        XCTAssertFalse(String(reflecting: snapshot).contains("SECRET"))
        XCTAssertTrue(snapshot.issues.allSatisfy { !$0.nextAction.label.isEmpty })
    }

    func testPreviewFailureIsRedactedAndTargetsPreviewRecovery() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        var preview = PreviewState()
        preview.open(try XCTUnwrap(URL(string: "http://localhost:3000/?token=SECRET_QUERY")))
        preview.markFailed("Authorization header SECRET_HEADER was rejected")

        let snapshot = await service.update(AttentionInput(
            projects: [project()],
            previews: ["project-1": preview]
        ))
        let issue = try XCTUnwrap(snapshot.issues.first)

        XCTAssertEqual(issue.severity, .warning)
        XCTAssertEqual(issue.sources, [.preview])
        XCTAssertEqual(issue.nextAction.kind, .retryPreview)
        XCTAssertEqual(
            issue.navigationTarget,
            .project(projectID: "project-1", surface: .preview)
        )
        XCTAssertFalse(String(reflecting: snapshot).contains("SECRET"))
        XCTAssertFalse(String(reflecting: snapshot).contains("token="))
    }

    func testResolvedIssuesLeaveActiveListAndHistoryIsBoundedAndRedacted() async {
        let timestamps = TimestampSequence()
        let service = AttentionService(
            maximumHistoryEntries: 5,
            now: { timestamps.next() }
        )
        var failedPreview = PreviewState()
        failedPreview.open(URL(string: "http://localhost:3000/?token=SECRET")!)
        failedPreview.markFailed("SECRET failure detail")

        for _ in 0..<6 {
            _ = await service.update(AttentionInput(
                projects: [project(name: "SECRET project")],
                previews: ["project-1": failedPreview]
            ))
            _ = await service.update(AttentionInput(projects: [project()]))
        }
        let snapshot = await service.currentSnapshot()

        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertEqual(snapshot.history.count, 5)
        XCTAssertEqual(snapshot.history.first?.event, .resolved)
        XCTAssertFalse(String(reflecting: snapshot.history).contains("SECRET"))
        XCTAssertTrue(snapshot.history.allSatisfy { $0.issueID.hasPrefix("attention:") })
        XCTAssertTrue(snapshot.history.allSatisfy { $0.scopeKind == .project })
    }

    func testLedgerFailureCreatesApplicationBlockerWithoutPersistingErrorText() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let snapshot = await service.update(AttentionInput(
            runtimeReconciliation: RuntimeReconciliationReport(
                items: [],
                ledgerError: "Could not read /secret/path containing SECRET_TOKEN"
            )
        ))
        let issue = try XCTUnwrap(snapshot.issues.first)

        XCTAssertEqual(issue.scope, .application)
        XCTAssertEqual(issue.severity, .blocker)
        XCTAssertEqual(issue.navigationTarget, .attention)
        XCTAssertFalse(String(reflecting: snapshot).contains("SECRET"))
        XCTAssertFalse(String(reflecting: snapshot).contains("/secret/path"))
    }

    func testIssuesSortBlockersBeforeWarningsThenByScope() async {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        var preview = PreviewState()
        preview.open(URL(string: "http://localhost:3000")!)
        preview.markFailed("failed")
        let snapshot = await service.update(AttentionInput(
            projects: [project(name: "Alpha"), project(id: "project-2", name: "Zulu")],
            runtimes: ["project-2": RuntimeSnapshot(
                status: .failed,
                terminalReason: .unexpectedExit(code: 1)
            )],
            previews: ["project-1": preview]
        ))

        XCTAssertEqual(snapshot.issues.map(\.severity), [.blocker, .warning])
        XCTAssertEqual(snapshot.issues.map(\.scope.displayName), ["Zulu", "Alpha"])
    }

    func testStaleRevisionCannotResolveNewerIssuesOrMutateHistory() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        var preview = PreviewState()
        preview.open(try XCTUnwrap(URL(string: "http://localhost:3000")))
        preview.markFailed("newer failure")

        let newer = await service.update(
            AttentionInput(projects: [project()], previews: ["project-1": preview]),
            revision: 2
        )
        let stale = await service.update(
            AttentionInput(projects: [project()]),
            revision: 1
        )

        XCTAssertEqual(stale, newer)
        XCTAssertEqual(stale.issues.first?.sources, [.preview])
        XCTAssertFalse(stale.history.contains { $0.event == .resolved })
    }

    func testWorkspaceOperationKeepsItsOriginatingTarget() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let operation = WorkspaceOperationSummary(
            results: [operationResult(
                status: .blocked,
                reason: "workspace-doctor-blocked",
                message: "blocked"
            )],
            target: .profile("origin-profile")
        )

        let snapshot = await service.update(AttentionInput(
            projects: [project()],
            workspaceOperation: operation
        ))
        let issue = try XCTUnwrap(snapshot.issues.first)

        XCTAssertEqual(
            issue.navigationTarget,
            .workspace(target: .profile("origin-profile"), projectID: "project-1")
        )

        XCTAssertNil(operation.resolvingAttention(for: "project-1"))
    }

    func testDependencyIssuesRouteToProjectDoctorInsteadOfMissingField() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        var diagnosis = ProjectDiagnosis.notChecked()
        diagnosis.status = .attention
        diagnosis.setCheck(
            .dependencies,
            status: .warn,
            message: "Dependency order needs review"
        )

        let projectSnapshot = await service.update(AttentionInput(
            projects: [project()],
            projectDiagnoses: ["project-1": diagnosis]
        ))
        XCTAssertEqual(
            try XCTUnwrap(projectSnapshot.issues.first).navigationTarget,
            .project(
                projectID: "project-1",
                surface: .doctor(check: .dependencies, suggestedAction: nil)
            )
        )

        let workspaceSnapshot = await service.update(AttentionInput(
            projects: [project()],
            workspaceDiagnosis: workspaceDiagnosis(
                check: .dependencies,
                severity: .warning,
                message: "Dependency order needs review"
            )
        ))
        XCTAssertEqual(
            try XCTUnwrap(workspaceSnapshot.issues.first).navigationTarget,
            .project(
                projectID: "project-1",
                surface: .doctor(check: .dependencies, suggestedAction: nil)
            )
        )
    }

    func testUnknownRuntimeOnlySurfacesUnresolvedOwnershipAtApplicationScope() async throws {
        let service = AttentionService(now: { "2026-07-19T00:00:00Z" })
        let safeTerminal = await service.update(AttentionInput(
            runtimes: ["deleted-project": RuntimeSnapshot(
                status: .failed,
                terminalReason: .unexpectedExit(code: 1)
            )]
        ))
        XCTAssertTrue(safeTerminal.issues.isEmpty)

        let unresolved = await service.update(AttentionInput(
            runtimeReconciliation: RuntimeReconciliationReport(
                items: [RuntimeReconciliationItem(
                    runID: "unlinked-run",
                    projectID: "unlinked-project",
                    classification: .unverifiable,
                    message: "Ownership could not be verified."
                )],
                ledgerError: nil
            )
        ))
        let issue = try XCTUnwrap(unresolved.issues.first)
        XCTAssertEqual(issue.scope, .application)
        XCTAssertEqual(issue.navigationTarget, .attention)
    }

    private func projectID(_ issue: AttentionIssue) -> String? {
        switch issue.scope {
        case .project(let id, _): id
        case .application, .workspace: nil
        }
    }

    private func project(id: String = "project-1", name: String = "Web") -> Project {
        Project(
            id: id,
            name: name,
            cwd: "/tmp/project",
            command: "node server.js",
            port: 3_000,
            url: "http://localhost:3000",
            createdAt: "2026-07-19T00:00:00Z",
            updatedAt: "2026-07-19T00:00:00Z"
        )
    }

    private func operationResult(
        projectID: String = "project-1",
        name: String = "Web",
        status: WorkspaceOperationItemStatus,
        reason: String?,
        message: String
    ) -> WorkspaceOperationResult {
        WorkspaceOperationResult(
            projectID: projectID,
            projectName: name,
            status: status,
            reason: reason,
            message: message,
            blockedByProjectIDs: [],
            blockedByProjectNames: []
        )
    }

    private func workspaceDiagnosis(
        check: WorkspaceCheckID,
        severity: WorkspaceIssueSeverity,
        message: String,
        target workspaceTarget: WorkspaceTarget = .allProjects,
        projectID: String = "project-1",
        projectName: String = "API",
        updatedAt: String = "2026-07-19T00:00:00Z"
    ) -> WorkspaceDiagnosis {
        let targetKind: WorkspaceTargetKind
        let profileID: String?
        let targetName: String
        switch workspaceTarget {
        case .allProjects:
            targetKind = .allProjects
            profileID = nil
            targetName = "All Projects"
        case .lastRunning:
            targetKind = .lastRunning
            profileID = nil
            targetName = "Last Running"
        case .profile(let id):
            targetKind = .profile
            profileID = id
            targetName = "Saved Workspace"
        }
        let target = ResolvedWorkspaceTarget(
            kind: targetKind,
            profileID: profileID,
            name: targetName,
            projectIDs: [projectID]
        )
        return WorkspaceDiagnosis(
            status: severity == .blocker ? .blocked : .attention,
            summary: "SECRET workspace summary",
            updatedAt: updatedAt,
            target: target,
            totals: WorkspaceDiagnosisTotals(
                projects: 1,
                ready: 0,
                warnings: severity == .warning ? 1 : 0,
                blockers: severity == .blocker ? 1 : 0
            ),
            startableProjectIDs: severity == .warning ? [projectID] : [],
            blockedProjectIDs: severity == .blocker ? [projectID] : [],
            checks: WorkspaceCheckID.allCases.map {
                WorkspaceDoctorCheck(
                    id: $0,
                    status: $0 == check ? (severity == .blocker ? .fail : .warn) : .pass,
                    message: $0 == check ? message : "Ready"
                )
            },
            projects: [WorkspaceProjectDiagnosis(
                id: projectID,
                name: projectName,
                status: severity == .blocker ? .blocked : .attention,
                summary: message,
                dependencyNames: [],
                issues: [WorkspaceIssue(
                    severity: severity,
                    check: check,
                    code: "secret-code",
                    message: message
                )]
            )]
        )
    }

    private func healthyWorkspaceDiagnosis(updatedAt: String) -> WorkspaceDiagnosis {
        let target = ResolvedWorkspaceTarget(
            kind: .allProjects,
            profileID: nil,
            name: "All Projects",
            projectIDs: ["project-1"]
        )
        return WorkspaceDiagnosis(
            status: .ready,
            summary: "Ready",
            updatedAt: updatedAt,
            target: target,
            totals: WorkspaceDiagnosisTotals(
                projects: 1,
                ready: 1,
                warnings: 0,
                blockers: 0
            ),
            startableProjectIDs: ["project-1"],
            blockedProjectIDs: [],
            checks: WorkspaceCheckID.allCases.map {
                WorkspaceDoctorCheck(id: $0, status: .pass, message: "Ready")
            },
            projects: []
        )
    }
}

private final class TimestampSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> String {
        lock.withLock {
            value += 1
            return "2026-07-19T00:00:\(String(format: "%02d", value))Z"
        }
    }
}
