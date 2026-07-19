import Foundation
import Observation

private struct AttentionRefreshPayload: Sendable {
    let attention: AttentionInput
    let projectPolicies: [String: MenuProjectValidatedPolicy]
    let workspacePolicies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy]
}

@MainActor
@Observable
final class AppModel {
    private(set) var projectCount: Int
    private(set) var workspaceCount: Int
    private(set) var runningProjectCount: Int
    private(set) var persistenceStatus: PersistenceStatus
    private(set) var projects: [Project]
    private(set) var workspace: WorkspaceState
    private(set) var runtimes: [String: RuntimeSnapshot]
    private(set) var workspaceDiagnosis: WorkspaceDiagnosis?
    private(set) var workspaceOperation: WorkspaceOperationSummary?
    private(set) var runtimeReconciliationReport: RuntimeReconciliationReport
    private(set) var runtimeBootstrapState: RuntimeBootstrapState
    private(set) var attentionSnapshot: AttentionSnapshot
    private(set) var previewFailures: [String: PreviewState]
    private(set) var runHistoryDocument: RunHistoryDocument
    private(set) var runHistoryErrorMessage: String?
    private(set) var isWorkspaceOperating: Bool
    private(set) var isCheckingForUpdates: Bool
    var releaseNotice: ReleaseNotice?
    var selectedWorkspaceTarget: WorkspaceTarget?
    var errorMessage: String?
    private(set) var menuActionFailureRevision: UInt64 = 0
    private(set) var repositoryOpenProposal: RepositoryOpenProposal?
    let navigationRouter: NavigationRouter
    let launchAtLoginService: LaunchAtLoginService
    let runtimeNotificationService: RuntimeNotificationService

    var repositoryProposal: RepositoryProposal? {
        guard case .project(let proposal) = repositoryOpenProposal else { return nil }
        return proposal
    }

    private let store: ProjectStore?
    private let runtimeService: RuntimeService
    private let doctorService: ProjectDoctorService
    private let reportBuilder: DoctorReportBuilder
    private let desktopActions: DesktopActionService
    private let workspaceDoctor: WorkspaceDoctorService
    private let workspaceOrchestration: WorkspaceOrchestrationService
    private let workspacePacks: WorkspacePackService
    private let attentionService: AttentionService
    private let runHistoryCoordinator: RunHistoryCoordinator?
    private let menuCommandCenterService: MenuCommandCenterService
    private let diagnosticNow: @Sendable () -> String
    private let releaseChecker: ReleaseCheckService
    private let currentVersion: @Sendable () -> String
    private let sampleService: SampleProjectService
    private let sampleDestination: @Sendable () -> URL
    private let directoryPicker: DirectoryPickerService
    private let repositoryOnboarding: RepositoryOnboardingService
    private var openedReadyRunIDs: Set<String>
    private var runtimeBootstrapGeneration = UUID()
    private var runtimeBootstrapTask: Task<Void, Never>?
    private var attentionRefreshTask: Task<Void, Never>?
    private var attentionDiagnosisTask: Task<AttentionRefreshPayload?, Never>?
    private var attentionRefreshGeneration = UUID()
    private var attentionRefreshRevision: UInt64 = 0
    private var workspaceOperationGeneration = UUID()
    private var retainedWorkspaceOperations: [WorkspaceTarget: WorkspaceOperationSummary]
    private var retainedWorkspaceOperationOrder: [WorkspaceTarget]
    private var runHistoryCaptures: [String: RunHistoryCapture]
    private var runHistoryTask: Task<Void, Never>?
    private var menuProjectPolicies: [String: MenuProjectValidatedPolicy]
    private var menuWorkspacePolicies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy]
    private var runtimeNotificationObservationTask: Task<Void, Never>?
    private var runtimeNotificationObservationRevision: UInt64 = 0
    private var isShuttingDown = false

    init(
        projectCount: Int = 0,
        workspaceCount: Int = 0,
        runningProjectCount: Int = 0,
        persistenceStatus: PersistenceStatus = .notLoaded,
        projects: [Project] = [],
        workspace: WorkspaceState = .empty,
        initialRuntimes: [String: RuntimeSnapshot] = [:],
        runtimeReconciliationReport: RuntimeReconciliationReport = .empty,
        runtimeBootstrapState: RuntimeBootstrapState = .ready,
        initialAttentionSnapshot: AttentionSnapshot = .empty,
        initialPreviewFailures: [String: PreviewState] = [:],
        initialRunHistoryDocument: RunHistoryDocument = .empty,
        initialMenuProjectPolicies: [String: MenuProjectValidatedPolicy] = [:],
        initialMenuWorkspacePolicies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy] = [:],
        store: ProjectStore? = nil,
        runtimeService: RuntimeService = RuntimeService(),
        doctorService: ProjectDoctorService = ProjectDoctorService(),
        reportBuilder: DoctorReportBuilder = DoctorReportBuilder(),
        desktopActions: DesktopActionService = .live,
        workspaceDoctor: WorkspaceDoctorService = WorkspaceDoctorService(),
        workspaceOrchestration: WorkspaceOrchestrationService? = nil,
        workspacePacks: WorkspacePackService = WorkspacePackService(),
        attentionService: AttentionService = AttentionService(),
        runHistoryCoordinator: RunHistoryCoordinator? = nil,
        menuCommandCenterService: MenuCommandCenterService = MenuCommandCenterService(),
        launchAtLoginService: LaunchAtLoginService? = nil,
        runtimeNotificationService: RuntimeNotificationService? = nil,
        diagnosticNow: @escaping @Sendable () -> String = {
            ISO8601DateFormatter().string(from: Date())
        },
        releaseChecker: ReleaseCheckService = ReleaseCheckService(),
        currentVersion: @escaping @Sendable () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0.0.0"
        },
        sampleService: SampleProjectService = SampleProjectService(),
        sampleDestination: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("LocalWrap Sample Project", isDirectory: true)
        },
        directoryPicker: DirectoryPickerService = .live,
        repositoryOnboarding: RepositoryOnboardingService? = nil,
        repositoryProposal: RepositoryProposal? = nil,
        repositoryOpenProposal: RepositoryOpenProposal? = nil,
        navigationRouter: NavigationRouter? = nil
    ) {
        self.projects = projects
        self.workspace = workspace
        self.projectCount = projects.isEmpty ? max(0, projectCount) : projects.count
        self.workspaceCount = workspace.savedWorkspaces.isEmpty
            ? max(0, workspaceCount)
            : workspace.savedWorkspaces.count
        self.runningProjectCount = initialRuntimes.isEmpty
            ? max(0, runningProjectCount)
            : initialRuntimes.values.count { $0.status.isActive }
        self.persistenceStatus = persistenceStatus
        runtimes = initialRuntimes
        workspaceDiagnosis = nil
        workspaceOperation = nil
        self.runtimeReconciliationReport = runtimeReconciliationReport
        self.runtimeBootstrapState = runtimeBootstrapState
        attentionSnapshot = initialAttentionSnapshot
        previewFailures = initialPreviewFailures
        runHistoryDocument = initialRunHistoryDocument
        runHistoryErrorMessage = nil
        isWorkspaceOperating = false
        isCheckingForUpdates = false
        releaseNotice = nil
        selectedWorkspaceTarget = nil
        self.store = store
        self.runtimeService = runtimeService
        self.doctorService = doctorService
        self.reportBuilder = reportBuilder
        self.desktopActions = desktopActions
        self.workspaceDoctor = workspaceDoctor
        self.workspaceOrchestration = workspaceOrchestration
            ?? WorkspaceOrchestrationService(runtime: runtimeService, doctor: workspaceDoctor)
        self.workspacePacks = workspacePacks
        self.attentionService = attentionService
        self.runHistoryCoordinator = runHistoryCoordinator
        self.menuCommandCenterService = menuCommandCenterService
        self.launchAtLoginService = launchAtLoginService ?? .inactive()
        self.runtimeNotificationService = runtimeNotificationService ?? .inactive()
        self.diagnosticNow = diagnosticNow
        self.releaseChecker = releaseChecker
        self.currentVersion = currentVersion
        self.sampleService = sampleService
        self.sampleDestination = sampleDestination
        self.directoryPicker = directoryPicker
        self.repositoryOnboarding = repositoryOnboarding
            ?? RepositoryOnboardingService(workspacePacks: workspacePacks)
        self.repositoryOpenProposal = repositoryOpenProposal
            ?? repositoryProposal.map(RepositoryOpenProposal.project)
        self.navigationRouter = navigationRouter ?? NavigationRouter(
            projects: projects,
            workspace: workspace
        )
        openedReadyRunIDs = []
        retainedWorkspaceOperations = [:]
        retainedWorkspaceOperationOrder = []
        runHistoryCaptures = [:]
        menuProjectPolicies = initialMenuProjectPolicies
        menuWorkspacePolicies = initialMenuWorkspacePolicies
        scheduleAttentionRefresh(immediate: true)
        scheduleRunHistoryLoad()
        scheduleRuntimeNotificationObservation()
    }

    static func live(
        store: ProjectStore = ProjectStore(),
        runtimeService: RuntimeService = RuntimeService(),
        doctorService: ProjectDoctorService = ProjectDoctorService(),
        reportBuilder: DoctorReportBuilder = DoctorReportBuilder(),
        desktopActions: DesktopActionService = .live,
        workspaceDoctor: WorkspaceDoctorService = WorkspaceDoctorService(),
        workspaceOrchestration: WorkspaceOrchestrationService? = nil,
        workspacePacks: WorkspacePackService = WorkspacePackService(),
        attentionService: AttentionService = AttentionService(),
        runHistoryCoordinator: RunHistoryCoordinator? = nil,
        launchAtLoginService: LaunchAtLoginService? = nil,
        runtimeNotificationService: RuntimeNotificationService? = nil,
        sessionStore: SessionStateStore = SessionStateStore(),
        releaseChecker: ReleaseCheckService = ReleaseCheckService(),
        currentVersion: @escaping @Sendable () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0.0.0"
        }
    ) -> AppModel {
        do {
            let result = try store.loadOrMigrate()
            let model = AppModel(
                persistenceStatus: .ready(result.outcome),
                projects: result.document.projects,
                workspace: result.document.workspace,
                runtimeBootstrapState: runtimeService.managesPersistentRuns ? .reconciling : .ready,
                store: store,
                runtimeService: runtimeService,
                doctorService: doctorService,
                reportBuilder: reportBuilder,
                desktopActions: desktopActions,
                workspaceDoctor: workspaceDoctor,
                workspaceOrchestration: workspaceOrchestration,
                workspacePacks: workspacePacks,
                attentionService: attentionService,
                runHistoryCoordinator: runHistoryCoordinator,
                launchAtLoginService: launchAtLoginService,
                runtimeNotificationService: runtimeNotificationService,
                releaseChecker: releaseChecker,
                currentVersion: currentVersion,
                navigationRouter: NavigationRouter(
                    store: sessionStore,
                    projects: result.document.projects,
                    workspace: result.document.workspace
                )
            )
            model.scheduleRuntimeBootstrap()
            return model
        } catch {
            let model = AppModel(
                persistenceStatus: .recoveryRequired(
                    message: error.localizedDescription,
                    backupAvailable: store.hasBackup()
                ),
                runtimeBootstrapState: runtimeService.managesPersistentRuns ? .reconciling : .ready,
                store: store,
                runtimeService: runtimeService,
                doctorService: doctorService,
                reportBuilder: reportBuilder,
                desktopActions: desktopActions,
                workspaceDoctor: workspaceDoctor,
                workspaceOrchestration: workspaceOrchestration,
                workspacePacks: workspacePacks,
                attentionService: attentionService,
                runHistoryCoordinator: runHistoryCoordinator,
                launchAtLoginService: launchAtLoginService,
                runtimeNotificationService: runtimeNotificationService,
                releaseChecker: releaseChecker,
                currentVersion: currentVersion
            )
            model.scheduleRuntimeBootstrap()
            return model
        }
    }

    static func forCurrentLaunch() -> AppModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-workspace-manifest-review") {
            let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            let packURL = root.appendingPathComponent(".localwrap/workspace.json")
            let webDraft = ProjectDraft(
                id: "web",
                name: "Web",
                cwd: "/tmp/apps/web",
                command: "npm run dev",
                port: 5_173,
                url: "http://localhost:5173",
                autostart: true,
                openOnReady: false,
                dependsOn: ["api"],
                healthCheck: HealthCheck(path: "/health")
            )
            let apiDraft = ProjectDraft(
                id: "api",
                name: "API",
                cwd: "/tmp/services/api",
                command: "node server.js",
                port: 4_000,
                url: "http://localhost:4000",
                openOnReady: true
            )
            let pack = ReviewedWorkspacePack(
                name: "Fixture Stack",
                rootURL: root,
                packURL: packURL,
                projects: [
                    ReviewedWorkspacePackProject(
                        id: "web",
                        name: "Web",
                        path: "apps/web",
                        draft: webDraft
                    ),
                    ReviewedWorkspacePackProject(
                        id: "api",
                        name: "API",
                        path: "services/api",
                        draft: apiDraft
                    ),
                ],
                profiles: [
                    ReviewedWorkspacePackProfile(
                        id: "default",
                        name: "Full Stack",
                        projectIDs: ["web", "api"]
                    ),
                ]
            )
            let review = WorkspacePackReview(
                name: "Fixture Stack",
                rootURL: root,
                packURL: packURL,
                version: 1,
                projects: [
                    WorkspacePackReviewProject(
                        id: "web",
                        name: "Web",
                        path: "apps/web",
                        command: "npm run dev",
                        port: 5_173,
                        url: "http://localhost:5173",
                        autostart: true,
                        openOnReady: false,
                        dependsOn: ["api"],
                        healthCheck: HealthCheck(path: "/health")
                    ),
                    WorkspacePackReviewProject(
                        id: "api",
                        name: "API",
                        path: "services/api",
                        command: "node server.js",
                        port: 4_000,
                        url: "http://localhost:4000",
                        autostart: false,
                        openOnReady: true,
                        dependsOn: [],
                        healthCheck: nil
                    ),
                ],
                profiles: [
                    WorkspacePackReviewProfile(
                        id: "default",
                        name: "Full Stack",
                        projectIDs: ["web", "api"]
                    ),
                ],
                issues: [
                    WorkspacePackReviewIssue(
                        code: "fixture-warning",
                        severity: .warning,
                        scope: "Project Web",
                        field: "url",
                        message: "Confirm the preview address before importing."
                    ),
                ],
                changes: [
                    WorkspacePackChange(
                        entity: .project,
                        entityID: "web",
                        name: "Web",
                        disposition: .update,
                        existingSavedID: "saved-web"
                    ),
                    WorkspacePackChange(
                        entity: .project,
                        entityID: "api",
                        name: "API",
                        disposition: .unchanged,
                        existingSavedID: "saved-api"
                    ),
                    WorkspacePackChange(
                        entity: .workspace,
                        entityID: "default",
                        name: "Full Stack",
                        disposition: .update,
                        existingSavedID: "saved-workspace"
                    ),
                ],
                pack: pack
            )
            let savedProjects = [
                Project(
                    id: "saved-web",
                    name: "Web",
                    cwd: "/tmp/apps/web",
                    command: "npm start",
                    port: 5_173,
                    url: "http://localhost:5173",
                    autostart: false,
                    openOnReady: true,
                    createdAt: "2026-07-10T00:00:00Z",
                    updatedAt: "2026-07-10T00:00:00Z",
                    dependsOn: ["saved-api"]
                ),
                Project(
                    id: "saved-api",
                    name: "API",
                    cwd: "/tmp/services/api",
                    command: "node server.js",
                    port: 4_000,
                    url: "http://localhost:4000",
                    openOnReady: true,
                    createdAt: "2026-07-10T00:00:00Z",
                    updatedAt: "2026-07-10T00:00:00Z"
                ),
            ]
            let savedWorkspace = WorkspaceState(
                lastRunningProjectIds: [],
                savedWorkspaces: [
                    WorkspaceProfile(
                        id: "saved-workspace",
                        name: "Frontend",
                        projectIds: ["saved-web"],
                        createdAt: "2026-07-10T00:00:00Z",
                        updatedAt: "2026-07-10T00:00:00Z",
                        lastStartedAt: nil,
                        source: nil
                    ),
                ],
                updatedAt: "2026-07-10T00:00:00Z"
            )
            return AppModel(
                projects: savedProjects,
                workspace: savedWorkspace,
                repositoryOpenProposal: .workspace(review)
            )
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-repository-review") {
            let draft = ProjectDraft(
                name: "Review Fixture",
                cwd: "/tmp",
                command: "npm run dev",
                port: 4_321,
                url: "http://localhost:4321"
            )
            return AppModel(repositoryProposal: RepositoryProposal(
                rootURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
                scripts: [PackageScript(
                    name: "dev",
                    command: "npm run dev",
                    script: "vite",
                    preferred: true
                )],
                warnings: [InspectionWarning(
                    field: ProjectField.command.rawValue,
                    code: "review-fixture",
                    message: "Confirm the detected command before adding this project."
                )],
                nameSource: .directoryName,
                commandSource: .packageScript,
                draft: draft
            ))
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-preview") {
            let id = "ui-preview"
            return AppModel(
                projects: [Project(
                    id: id,
                    name: "Preview Fixture",
                    cwd: "/tmp",
                    command: "npm start",
                    port: 4_321,
                    url: "http://localhost:4321",
                    createdAt: "2026-07-11T00:00:00Z",
                    updatedAt: "2026-07-11T00:00:00Z"
                )],
                initialRuntimes: [
                    id: RuntimeSnapshot(
                        status: .ready,
                        runID: "ui-preview-run",
                        ownership: .verified(runID: "ui-preview-run"),
                        readinessMessage: "Ready for preview."
                    ),
                ],
                navigationRouter: NavigationRouter(selection: .project(id))
            )
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-runtime-reconciliation") {
            let id = "ui-runtime-conflict"
            return AppModel(
                projects: [Project(
                    id: id,
                    name: "Recovered Runtime",
                    cwd: "/tmp",
                    command: "npm start",
                    port: 4_321,
                    url: "http://localhost:4321",
                    createdAt: "2026-07-18T00:00:00Z",
                    updatedAt: "2026-07-18T00:00:00Z"
                )],
                initialRuntimes: [
                    id: RuntimeSnapshot(
                        status: .runningUnresponsive,
                        runID: "fixture-run",
                        ownership: .conflicting(
                            runID: "fixture-run",
                            reason: .identityMismatch
                        ),
                        terminalReason: .ownershipConflict,
                        pid: 7_001,
                        logs: ["[reconciliation] Process identity changed."],
                        startedAt: "2026-07-18T00:00:00Z",
                        readinessMessage: "The recorded process identity no longer matches. LocalWrap did not signal it."
                    ),
                ],
                navigationRouter: NavigationRouter(selection: .project(id))
            )
        }
        #endif
        return live(
            runtimeService: .live(),
            runHistoryCoordinator: RunHistoryCoordinator(),
            launchAtLoginService: LaunchAtLoginService(),
            runtimeNotificationService: RuntimeNotificationService()
        )
    }

    var menuStatusSummary: String {
        MenuStatusFormatter.summary(running: runningProjectCount, saved: projectCount)
    }

    /// A pure projection over current state plus policies prepared by the
    /// background diagnosis batch. Reading this property never touches the
    /// filesystem, parses a URL, or invokes either Doctor service.
    var menuCommandCenterSnapshot: MenuCommandCenterSnapshot {
        menuCommandCenterService.snapshot(MenuCommandCenterInput(
            projects: projects,
            runtimes: runtimes,
            policies: menuProjectPolicies,
            workspacePolicies: menuWorkspacePolicies,
            workspace: workspace,
            attention: attentionSnapshot,
            permitsRuntimeMutation: runtimeControlsAvailable,
            workspaceOperationInProgress: isWorkspaceOperating
        ))
    }

    var runtimeControlsAvailable: Bool {
        runtimeBootstrapState.permitsMutation && !isShuttingDown
    }

    var attentionCount: Int { attentionSnapshot.count }

    var readyProjects: [Project] {
        projects.filter { runtime(for: $0.id).status == .ready }
    }

    var activeProjects: [Project] {
        projects.filter { runtime(for: $0.id).status.isActive }
    }

    func requestStartProject(id: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await startProject(id: id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestRestartProject(id: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await restartProject(id: id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func executeMenuPrimaryAction(_ requested: MenuCommandCenterPrimaryAction) {
        let current = menuCommandCenterSnapshot
        guard current.primaryAction == requested else {
            rejectStaleMenuAction()
            return
        }

        switch requested.kind {
        case .reviewFailure:
            if let issueID = requested.attentionIssueID,
               let issue = attentionSnapshot.issues.first(where: { $0.id == issueID }) {
                openAttentionIssue(issue)
            } else if let target = requested.reviewTarget {
                navigationRouter.showAttentionTarget(target)
            } else {
                navigationRouter.show(.attention)
            }
            errorMessage = nil

        case .openReadyApps:
            if !openMenuProjectURLs(requested.projectIDs) {
                reportMenuActionFailure("No validated ready app is available to open.")
            }

        case .resume:
            performMenuWorkspaceStart(target: .lastRunning)
        }
    }

    func executeMenuProjectAction(projectID: String, action: MenuProjectAction) {
        let current = menuCommandCenterSnapshot
        guard let actions = current.quickActions(for: projectID) else {
            rejectStaleMenuAction()
            return
        }
        let capability = menuCapability(action, in: actions)
        guard capability.isEnabled else {
            reportMenuActionFailure(
                capability.disabledReason ?? "This action is no longer available."
            )
            return
        }

        switch action {
        case .start:
            requestMenuStartProject(id: projectID)
        case .stop:
            Task { @MainActor [weak self] in
                guard let self else { return }
                errorMessage = nil
                await stopProject(id: projectID)
                let state = runtime(for: projectID)
                if let message = errorMessage
                    ?? (state.status == .failed
                        ? state.error ?? state.readinessMessage ?? "The app could not be stopped safely."
                        : nil) {
                    reportMenuActionFailure(message)
                }
            }
        case .restart:
            requestMenuRestartProject(id: projectID)
        case .open:
            if !openMenuProjectURLs([projectID]) {
                reportMenuActionFailure("This app is no longer ready to open.")
            }
        case .review:
            if let issue = attentionSnapshot.issues.first(where: {
                if case .project(let id, _) = $0.scope { return id == projectID }
                return false
            }) {
                openAttentionIssue(issue)
            } else {
                navigationRouter.showAttentionTarget(
                    .project(projectID: projectID, surface: .runtime)
                )
            }
        }
    }

    func executeMenuWorkspaceAction(_ action: MenuWorkspaceAction) {
        let actions = menuCommandCenterSnapshot.workspaceQuickActions
        let capability: MenuActionCapability
        switch action {
        case .resume:
            capability = actions.resume
        case .startAll:
            capability = actions.startAll
        case .stopAll:
            capability = actions.stopAll
        case .openReadyApps:
            capability = actions.openReadyApps
        case .startSavedProfile(let profileID):
            guard let saved = actions.savedWorkspaces.first(where: {
                $0.profileID == profileID
            }) else {
                rejectStaleMenuAction()
                return
            }
            capability = saved.start
        }
        guard capability.isEnabled else {
            reportMenuActionFailure(
                capability.disabledReason ?? "This action is no longer available."
            )
            return
        }

        switch action {
        case .resume:
            performMenuWorkspaceStart(target: .lastRunning)
        case .startAll:
            performMenuWorkspaceStart(target: .allProjects)
        case .stopAll:
            performMenuStopAll()
        case .openReadyApps:
            if !openMenuProjectURLs(actions.readyProjectIDs) {
                reportMenuActionFailure("No validated ready app is available to open.")
            }
        case .startSavedProfile(let profileID):
            performMenuWorkspaceStart(target: .profile(profileID))
        }
    }

    func openMenuAttentionItem(_ requested: MenuCommandCenterItem) {
        let current = menuCommandCenterSnapshot.visibleGroups
            .flatMap(\.items)
            .first { $0.id == requested.id }
        guard let current else {
            rejectStaleMenuAction()
            return
        }
        if let issueID = current.attentionIssueID,
           let issue = attentionSnapshot.issues.first(where: { $0.id == issueID }) {
            openAttentionIssue(issue)
        } else if let target = current.reviewTarget {
            navigationRouter.showAttentionTarget(target)
        } else {
            navigationRouter.show(.attention)
        }
        errorMessage = nil
    }

    func showMenuOverflow() {
        navigationRouter.show(attentionSnapshot.issues.isEmpty ? .projects : .attention)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        switch launchAtLoginService.setEnabled(enabled) {
        case .success:
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func openLaunchAtLoginSettings() {
        launchAtLoginService.openSystemSettings()
    }

    func setRuntimeNotificationsEnabled(_ enabled: Bool) async {
        await runtimeNotificationService.setOptedIn(enabled)
        if let error = runtimeNotificationService.lastError {
            errorMessage = error.localizedDescription
        } else {
            errorMessage = nil
        }
        scheduleRuntimeNotificationObservation()
    }

    func openRuntimeNotificationSettings() {
        desktopActions.openNotificationSettings()
    }

    func refreshAmbientServices() {
        launchAtLoginService.refresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await runtimeNotificationService.refreshAuthorization()
            if let error = runtimeNotificationService.lastError {
                errorMessage = error.localizedDescription
            }
        }
    }

    func handleNotificationResponse(identifier: String) {
        guard case .project(let projectID, _) = runtimeNotificationService
            .navigationTarget(forNotificationIdentifier: identifier) else {
            return
        }
        let currentRuntime = runtime(for: projectID)
        if currentRuntime.status == .failed,
           runtimeNotificationService.notificationEventMatchesCurrentRuntime(
               identifier: identifier,
               projectID: projectID,
               runtime: currentRuntime
           ),
           let issue = attentionSnapshot.issues.first(where: {
               guard $0.sources.contains(.runtime),
                     case .project(let issueProjectID, _) = $0.scope else { return false }
               return issueProjectID == projectID
           }) {
            openAttentionIssue(issue)
        } else {
            navigationRouter.showAttentionTarget(
                .project(projectID: projectID, surface: .runtime)
            )
        }
    }

    func project(id: String) -> Project? {
        projects.first { $0.id == id }
    }

    func chooseRepository() {
        guard let directory = directoryPicker.choose() else { return }
        reviewRepository(at: directory)
    }

    func reviewRepository(at directory: URL) {
        do {
            repositoryOpenProposal = try repositoryOnboarding.openProposal(
                directory: directory,
                projects: projects,
                workspace: workspace
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissRepositoryProposal() {
        repositoryOpenProposal = nil
    }

    func runtime(for projectID: String) -> RuntimeSnapshot {
        runtimes[projectID] ?? RuntimeSnapshot()
    }

    func diagnose(_ draft: ProjectDraft) -> ProjectDiagnosis {
        doctorService.diagnose(draft)
    }

    func reportPreviewState(projectID: String, state: PreviewState) {
        if state.status == .failed {
            let previousIdentity = previewFailures[projectID]?.attentionFailureEvidence
            let nextIdentity = state.attentionFailureEvidence
            guard previousIdentity != nextIdentity else { return }
            previewFailures[projectID] = state
            scheduleAttentionRefresh()
        } else if previewFailures.removeValue(forKey: projectID) != nil {
            scheduleAttentionRefresh()
        }
    }

    func openAttentionIssue(_ issue: AttentionIssue) {
        navigationRouter.showAttentionTarget(issue.navigationTarget)
    }

    func performAttentionAction(
        _ issue: AttentionIssue,
        confirmed: Bool = false
    ) async {
        var actionableIssue = issue
        let mutatesSavedConfiguration: Bool
        if case .doctor(let action) = issue.nextAction.kind {
            mutatesSavedConfiguration = action.mutatesProject
        } else {
            mutatesSavedConfiguration = false
        }

        if issue.nextAction.requiresConfirmation || mutatesSavedConfiguration {
            guard confirmed else {
                errorMessage = "Confirm this saved configuration change before applying it."
                return
            }
            guard let currentIssue = attentionSnapshot.issues.first(where: { $0.id == issue.id }),
                  currentIssue.nextAction == issue.nextAction,
                  currentIssue.navigationTarget == issue.navigationTarget else {
                errorMessage = "This issue changed before the fix was applied. Review its current state and try again."
                scheduleAttentionRefresh(immediate: true)
                return
            }
            actionableIssue = currentIssue
        }

        switch actionableIssue.nextAction.kind {
        case .navigate, .retryPreview:
            navigationRouter.showAttentionTarget(actionableIssue.navigationTarget)

        case .reconcileRuntime:
            await reconcileRuntimeOwnership()
            navigationRouter.showAttentionTarget(actionableIssue.navigationTarget)

        case .doctor(let action):
            guard case .project(let projectID, let surface) = actionableIssue.navigationTarget,
                  let project = project(id: projectID) else {
                navigationRouter.showAttentionTarget(actionableIssue.navigationTarget)
                return
            }
            let draft = ProjectDraft(project: project)
            let diagnosis = doctorService.diagnose(draft)
            if action.mutatesProject {
                guard case .doctor(let check, _) = surface,
                      diagnosis.check(check).actions.contains(action) else {
                    errorMessage = "This saved configuration fix is no longer needed. Review the current Doctor result."
                    scheduleAttentionRefresh(immediate: true)
                    return
                }
            }
            _ = await performDoctorAction(
                action,
                draft: draft,
                existingID: projectID,
                isDirty: false,
                diagnosis: diagnosis
            )
            navigationRouter.showAttentionTarget(actionableIssue.navigationTarget)
            scheduleAttentionRefresh(immediate: true)
        }
    }

    func clearAttentionHistory() async {
        attentionSnapshot = await attentionService.clearHistory()
    }

    func buildSupportReport() async -> SupportReport? {
        guard let runHistoryCoordinator else { return nil }
        await runHistoryTask?.value
        do {
            let report = try await runHistoryCoordinator.supportReport(
                generatedAt: diagnosticNow()
            )
            runHistoryErrorMessage = nil
            return report
        } catch {
            runHistoryErrorMessage = error.localizedDescription
            return nil
        }
    }

    func copySupportReport(_ report: SupportReport) {
        desktopActions.copyText(report.copyText)
    }

    func buildDoctorReport(
        draft: ProjectDraft,
        existingID: String?,
        diagnosis: ProjectDiagnosis
    ) -> DoctorReport {
        let runtime = existingID.map { self.runtime(for: $0) } ?? RuntimeSnapshot()
        let reportProject = existingID
            .flatMap { project(id: $0) }
            .map(ProjectDraft.init(project:)) ?? draft
        return reportBuilder.report(
            project: reportProject,
            runtime: runtime,
            diagnosis: diagnosis
        )
    }

    func copyDoctorReport(_ report: DoctorReport) {
        desktopActions.copyText(report.copyText)
    }

    func clearRunHistory(projectID: String? = nil) async {
        guard let runHistoryCoordinator else { return }
        await runHistoryTask?.value
        do {
            if let projectID {
                runHistoryDocument = try await runHistoryCoordinator.clear(projectID: projectID)
                runHistoryCaptures[projectID] = nil
            } else {
                runHistoryDocument = try await runHistoryCoordinator.clearAll()
                runHistoryCaptures = [:]
            }
            runHistoryErrorMessage = nil
        } catch {
            runHistoryErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveProject(
        draft: ProjectDraft,
        existingID: String?,
        startAfterSave: Bool
    ) async -> Project? {
        guard let store else { return nil }
        do {
            let project: Project
            if let existingID {
                try guardActiveProjectMutation(id: existingID, draft: draft)
                project = try store.updateProject(id: existingID, draft)
            } else {
                project = try store.createProject(draft)
            }
            try reloadPersistence()
            errorMessage = nil
            if startAfterSave {
                do {
                    try await startProject(id: project.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func performDoctorAction(
        _ actionID: String,
        draft: ProjectDraft,
        existingID: String?,
        isDirty: Bool,
        diagnosis: ProjectDiagnosis
    ) async -> ProjectDraft? {
        guard let action = DoctorActionID(rawValue: actionID) else {
            errorMessage = DoctorError.unknownAction(actionID).localizedDescription
            return nil
        }
        return await performDoctorAction(
            action,
            draft: draft,
            existingID: existingID,
            isDirty: isDirty,
            diagnosis: diagnosis
        )
    }

    @discardableResult
    func performDoctorAction(
        _ action: DoctorActionID,
        draft: ProjectDraft,
        existingID: String?,
        isDirty: Bool,
        diagnosis: ProjectDiagnosis
    ) async -> ProjectDraft? {
        do {
            switch action {
            case .revealFolder:
                desktopActions.revealFolder(URL(fileURLWithPath: draft.cwd, isDirectory: true))
                return draft
            case .copyReport:
                throw DoctorError.reportPreviewRequired
            case .revealCommand:
                return draft
            case .findFreePort, .syncURL:
                let patched = try doctorService.actionPatch(for: draft, action: action)
                guard let existingID else { return patched }
                guard !isDirty else { throw DoctorError.dirtyProject }
                guard !runtime(for: existingID).status.isActive else { throw DoctorError.activeProject }
                guard let store else { return nil }
                let saved = try store.updateProject(id: existingID, patched)
                try reloadPersistence()
                let state = await runtimeService.refreshDiagnosis(for: saved)
                receiveRuntime(projectID: existingID, state: state)
                errorMessage = nil
                return ProjectDraft(project: saved)
            }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteProject(id: String) {
        guard let store else { return }
        do {
            try store.deleteProject(id: id)
            try reloadPersistence()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func trySampleProject(bundle: Bundle = .main) -> Project? {
        guard let store else { return nil }
        do {
            if let existing = projects.first(where: \.isSample) {
                errorMessage = nil
                return existing
            }
            let copied = try sampleService.copyBundledSample(to: sampleDestination(), bundle: bundle)
            let project = try store.createProject(ProjectDraft(
                name: "LocalWrap Sample",
                cwd: copied.destination.path,
                command: "node server.js",
                port: 4_321,
                url: "http://localhost:4321",
                autostart: false,
                openOnReady: true,
                isSample: true
            ))
            try reloadPersistence()
            errorMessage = nil
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func recover(_ choice: RecoveryChoice) -> Bool {
        guard let store else { return false }
        do {
            let result = try store.recover(choice)
            guard result != .quit else { return false }
            let document = try store.load()
            projects = document.projects
            workspace = document.workspace
            projectCount = projects.count
            workspaceCount = workspace.savedWorkspaces.count
            persistenceStatus = .ready(.existingNativeStore)
            navigationRouter.revalidate(projects: projects, workspace: workspace)
            scheduleRuntimeBootstrap()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startProject(id: String) async throws {
        try requireRuntimeBootstrap()
        guard let project = project(id: id) else { return }
        do {
            let state = try await runtimeService.start(project)
            receiveRuntime(projectID: id, state: state)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func stopProject(id: String) async {
        guard runtimeControlsAvailable else {
            errorMessage = runtimeBootstrapMessage
            return
        }
        let state = await runtimeService.stop(projectID: id)
        receiveRuntime(projectID: id, state: state)
    }

    func restartProject(id: String) async throws {
        try requireRuntimeBootstrap()
        guard let project = project(id: id) else { return }
        do {
            let state = try await runtimeService.restart(project)
            receiveRuntime(projectID: id, state: state)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func clearLogs(projectID: String) async {
        await runtimeService.clearLogs(projectID: projectID)
    }

    func openProjectURL(id: String) {
        guard let project = project(id: id), runtime(for: id).status == .ready else { return }
        openValidatedLocalURL(project.url)
    }

    func openReadyProjectURLs() {
        for project in readyProjects {
            openValidatedLocalURL(project.url)
        }
    }

    func openExternalWebURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return
        }
        desktopActions.openURL(url)
    }

    func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            switch try await releaseChecker.check(currentVersion: currentVersion()) {
            case .upToDate(let current, let latest):
                releaseNotice = ReleaseNotice(
                    title: "LocalWrapMac is up to date",
                    message: "You are running version \(current). The latest stable release is \(latest).",
                    releaseURL: nil
                )
            case .updateAvailable(_, let latest, let releaseURL):
                releaseNotice = ReleaseNotice(
                    title: "LocalWrap \(latest) is available",
                    message: "A newer stable release is available on GitHub.",
                    releaseURL: releaseURL
                )
            }
        } catch {
            releaseNotice = ReleaseNotice(
                title: "Update check failed",
                message: error.localizedDescription,
                releaseURL: nil
            )
        }
    }

    func openReleasePage(_ url: URL) {
        guard ReleaseCheckService.isTrustedReleaseURL(url) else { return }
        desktopActions.openURL(url)
    }

    func diagnoseWorkspace(target: WorkspaceTarget? = nil) {
        do {
            selectedWorkspaceTarget = target
            workspaceDiagnosis = try workspaceDoctor.diagnose(
                projects: projects,
                workspace: workspace,
                target: target,
                runtimes: runtimes
            )
            scheduleAttentionRefresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startWorkspace(target: WorkspaceTarget? = nil, readyOnly: Bool) async {
        guard runtimeControlsAvailable else {
            errorMessage = runtimeBootstrapMessage
            return
        }
        guard !isWorkspaceOperating else { return }
        let generation = UUID()
        workspaceOperationGeneration = generation
        isWorkspaceOperating = true
        selectedWorkspaceTarget = target
        defer {
            if workspaceOperationGeneration == generation {
                isWorkspaceOperating = false
            }
        }
        do {
            let (diagnosis, operation) = try await workspaceOrchestration.start(
                projects: projects,
                workspace: workspace,
                target: target,
                startReadyOnly: readyOnly
            )
            guard workspaceOperationGeneration == generation else { return }
            workspaceDiagnosis = diagnosis
            let operationTarget = target ?? .allProjects
            workspaceOperation = operation.bound(to: operationTarget)
            retainWorkspaceOperation(operation, target: operationTarget)
            if let profileID = diagnosis.target.profileID {
                _ = try store?.markWorkspaceStarted(id: profileID)
            }
            try captureActiveProjectIDs(fallback: operation.results
                .filter { $0.status == .started || $0.reason == "already-active" }
                .map(\.projectID))
            try reloadPersistence()
            scheduleAttentionRefresh(immediate: true)
            errorMessage = nil
        } catch {
            guard workspaceOperationGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func stopAllProjects() async {
        guard runtimeControlsAvailable else {
            errorMessage = runtimeBootstrapMessage
            return
        }
        let generation = UUID()
        workspaceOperationGeneration = generation
        do { try captureActiveProjectIDs() }
        catch { errorMessage = error.localizedDescription }
        isWorkspaceOperating = true
        await workspaceOrchestration.stopAll()
        guard workspaceOperationGeneration == generation else { return }
        for (projectID, state) in await runtimeService.allSnapshots() {
            receiveRuntime(projectID: projectID, state: state)
        }
        isWorkspaceOperating = false
        workspaceOperation = nil
        scheduleAttentionRefresh(immediate: true)
    }

    @discardableResult
    func saveWorkspaceProfile(id: String?, name: String, projectIDs: [String]) -> WorkspaceProfile? {
        guard let store else { return nil }
        do {
            let profile = try store.upsertWorkspaceProfile(id: id, name: name, projectIDs: projectIDs)
            try reloadPersistence()
            errorMessage = nil
            return profile
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func importWorkspacePack(_ review: WorkspacePackReview) -> Bool {
        if let reason = workspacePackImportBlockReason(for: review) {
            errorMessage = reason
            return false
        }
        guard let store else { return false }
        do {
            try requireRuntimeBootstrap()
            _ = try workspacePacks.importReviewed(review, into: store)
            try reloadPersistence()
            selectedWorkspaceTarget = .allProjects
            workspaceDiagnosis = try workspaceDoctor.diagnose(
                projects: projects,
                workspace: workspace,
                target: selectedWorkspaceTarget,
                runtimes: runtimes
            )
            scheduleAttentionRefresh()
            repositoryOpenProposal = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func workspacePackImportBlockReason(for review: WorkspacePackReview) -> String? {
        guard review.canImport, review.pack != nil else {
            return review.blockers.first?.message
                ?? "Workspace pack is not ready to import."
        }
        let activeUpdateIDs = workspacePackActiveUpdateProjectIDs(for: review)
        guard activeUpdateIDs.isEmpty else {
            let names = activeUpdateIDs
                .map { project(id: $0)?.name ?? $0 }
                .sorted()
                .joined(separator: ", ")
            return "Stop these projects before importing configuration changes: \(names)."
        }
        return nil
    }

    func workspacePackActiveUpdateProjectIDs(for review: WorkspacePackReview) -> [String] {
        review.changes.compactMap { change in
            guard change.entity == .project,
                  change.disposition == .update,
                  let projectID = change.existingSavedID,
                  runtime(for: projectID).status.isActive
                    || runtime(for: projectID).ownership.hasUnresolvedRun else { return nil }
            return projectID
        }
    }

    func stopProjectsBlockingWorkspacePackImport(_ review: WorkspacePackReview) async {
        for projectID in workspacePackActiveUpdateProjectIDs(for: review) {
            await stopProject(id: projectID)
        }
    }

    func revealWorkspaceManifest(_ review: WorkspacePackReview) {
        desktopActions.revealFolder(review.packURL)
    }

    func copyWorkspaceManifestPath(_ review: WorkspacePackReview) {
        desktopActions.copyText(review.packURL.path)
    }

    func reviewWorkspaceManifestAgain(_ review: WorkspacePackReview) {
        reviewRepository(at: review.rootURL)
    }

    func exportWorkspacePack(rootURL: URL, overwrite: Bool) -> WorkspacePackExportResult? {
        do {
            let result = try workspacePacks.buildExport(
                rootURL: rootURL,
                projects: projects,
                workspace: workspace
            )
            _ = try workspacePacks.writeExport(result, rootURL: rootURL, overwrite: overwrite)
            errorMessage = nil
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func shutdown() async -> RuntimeShutdownReport {
        isShuttingDown = true
        defer {
            isShuttingDown = false
            scheduleAttentionRefresh(immediate: true)
            scheduleRuntimeNotificationObservation()
        }
        runtimeBootstrapGeneration = UUID()
        runtimeBootstrapTask?.cancel()
        runtimeBootstrapTask = nil
        attentionRefreshGeneration = UUID()
        let pendingAttentionRefresh = attentionRefreshTask
        let pendingAttentionDiagnosis = attentionDiagnosisTask
        pendingAttentionRefresh?.cancel()
        pendingAttentionDiagnosis?.cancel()
        attentionRefreshTask = nil
        attentionDiagnosisTask = nil
        runtimeNotificationObservationRevision &+= 1
        let pendingNotificationObservation = runtimeNotificationObservationTask
        pendingNotificationObservation?.cancel()
        runtimeNotificationObservationTask = nil
        workspaceOperationGeneration = UUID()
        isWorkspaceOperating = false
        await pendingAttentionRefresh?.value
        _ = await pendingAttentionDiagnosis?.value
        await pendingNotificationObservation?.value
        try? captureActiveProjectIDs()
        await workspaceOrchestration.cancelCurrentOperation()
        if runtimeService.managesPersistentRuns, !runtimeBootstrapState.permitsMutation {
            let report = await runtimeService.reconcile(projects: projects)
            runtimeReconciliationReport = report
            for (projectID, state) in await runtimeService.allSnapshots() {
                receiveRuntime(projectID: projectID, state: state)
            }
        }
        let report = await runtimeService.stopAllWithReport()
        await Task.yield()
        await runHistoryTask?.value
        return report
    }

    private func reconcileRuntimeOwnership() async {
        guard runtimeService.managesPersistentRuns, !isShuttingDown else { return }
        runtimeBootstrapGeneration = UUID()
        runtimeBootstrapTask?.cancel()
        runtimeBootstrapTask = nil
        runtimeBootstrapState = .reconciling
        let report = await runtimeService.reconcile(projects: projects)
        runtimeReconciliationReport = report
        for (projectID, state) in await runtimeService.allSnapshots() {
            receiveRuntime(projectID: projectID, state: state)
        }
        if let ledgerError = report.ledgerError {
            runtimeBootstrapState = .blocked(ledgerError)
            errorMessage = ledgerError
        } else {
            runtimeBootstrapState = .ready
            errorMessage = nil
        }
        scheduleAttentionRefresh(immediate: true)
    }

    private func reloadPersistence() throws {
        guard let store else { return }
        let document = try store.load()
        projects = document.projects
        workspace = document.workspace
        projectCount = projects.count
        workspaceCount = workspace.savedWorkspaces.count
        let projectIDs = Set(projects.map(\.id))
        previewFailures = previewFailures.filter { projectIDs.contains($0.key) }
        pruneRetainedWorkspaceOperations(projectIDs: projectIDs)
        menuProjectPolicies = menuProjectPolicies.filter { projectIDs.contains($0.key) }
        menuWorkspacePolicies = [:]
        navigationRouter.revalidate(projects: projects, workspace: workspace)
        scheduleAttentionRefresh()
        scheduleRuntimeNotificationObservation()
    }

    private func openValidatedLocalURL(_ value: String) {
        guard let url = LocalURLValidator().url(from: value) else { return }
        desktopActions.openURL(url)
    }

    @discardableResult
    private func openMenuProjectURLs(_ projectIDs: [String]) -> Bool {
        var visited = Set<String>()
        var openedAny = false
        for projectID in projectIDs where visited.insert(projectID).inserted {
            guard let project = project(id: projectID),
                  runtime(for: projectID).status == .ready,
                  menuProjectPolicies[projectID]?.canOpenValidatedLocalURL == true else {
                continue
            }
            openValidatedLocalURL(project.url)
            openedAny = true
        }
        return openedAny
    }

    private func menuCapability(
        _ action: MenuProjectAction,
        in actions: MenuProjectQuickActions
    ) -> MenuActionCapability {
        switch action {
        case .start: actions.start
        case .stop: actions.stop
        case .restart: actions.restart
        case .open: actions.open
        case .review: actions.review
        }
    }

    private func rejectStaleMenuAction() {
        reportMenuActionFailure(
            "LocalWrap changed since the menu opened. Review the current state and try again."
        )
    }

    private func reportMenuActionFailure(_ message: String) {
        errorMessage = message
        menuActionFailureRevision &+= 1
    }

    private func requestMenuStartProject(id: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startProject(id: id)
            } catch {
                self.reportMenuActionFailure(error.localizedDescription)
            }
        }
    }

    private func requestMenuRestartProject(id: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.restartProject(id: id)
            } catch {
                self.reportMenuActionFailure(error.localizedDescription)
            }
        }
    }

    private func performMenuWorkspaceStart(target: WorkspaceTarget) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.errorMessage = nil
            await self.startWorkspace(target: target, readyOnly: false)
            if let message = self.errorMessage {
                self.reportMenuActionFailure(message)
            } else if let failure = self.workspaceOperation?.unresolvedResults.first {
                self.reportMenuActionFailure(failure.message)
            }
        }
    }

    private func performMenuStopAll() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.errorMessage = nil
            await self.stopAllProjects()
            if let message = self.errorMessage {
                self.reportMenuActionFailure(message)
            } else if let failed = self.runtimes.values.first(where: {
                $0.status == .failed || $0.ownership.requiresOwnershipReview
            }) {
                self.reportMenuActionFailure(
                    failed.error
                        ?? failed.readinessMessage
                        ?? "One or more apps could not be stopped safely."
                )
            }
        }
    }

    private func scheduleRuntimeNotificationObservation() {
        guard !isShuttingDown else { return }
        runtimeNotificationObservationRevision &+= 1
        let revision = runtimeNotificationObservationRevision
        let previous = runtimeNotificationObservationTask
        let projectsSnapshot = projects
        let runtimesSnapshot = runtimes
        let service = runtimeNotificationService

        runtimeNotificationObservationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled,
                  let self,
                  self.runtimeNotificationObservationRevision == revision,
                  !self.isShuttingDown else { return }
            await service.observe(projects: projectsSnapshot, runtimes: runtimesSnapshot)
        }
    }

    private func guardActiveProjectMutation(id: String, draft: ProjectDraft) throws {
        let runtime = runtime(for: id)
        guard runtime.status.isActive || runtime.ownership.hasUnresolvedRun,
              let saved = project(id: id) else { return }
        if saved.cwd != draft.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            || saved.command != draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
            || saved.port != draft.port
            || saved.url != draft.url.trimmingCharacters(in: .whitespacesAndNewlines) {
            throw DoctorError.activeProject
        }
    }

    private func receiveRuntime(projectID: String, state: RuntimeSnapshot) {
        let previous = runtimes[projectID]
        let previousStatus = previous?.status ?? .stopped
        runtimes[projectID] = state
        runningProjectCount = runtimes.values.count { $0.status.isActive }
        captureRunHistory(projectID: projectID, previous: previous, current: state)
        if state.status == .ready,
           previousStatus != .ready,
           !state.recoveredAfterRelaunch,
           let runID = state.runID,
           !openedReadyRunIDs.contains(runID),
           let project = project(id: projectID), project.openOnReady {
            openedReadyRunIDs.insert(runID)
            openValidatedLocalURL(project.url)
        } else if !state.status.isActive {
            if let runID = state.runID ?? previous?.runID {
                openedReadyRunIDs.remove(runID)
            }
        }
        let clearedPreviewFailure = state.status != .ready
            && previewFailures.removeValue(forKey: projectID) != nil
        let resolvedWorkspaceFailure: Bool
        if state.status == .ready || state.terminalReason == .intentionalStop {
            resolvedWorkspaceFailure = resolveRetainedWorkspaceOperations(projectID: projectID)
            if let operation = workspaceOperation {
                workspaceOperation = operation.resolvingAttention(for: projectID)
            }
        } else {
            resolvedWorkspaceFailure = false
        }
        if runtimeAttentionChanged(from: previous, to: state)
            || clearedPreviewFailure
            || resolvedWorkspaceFailure {
            scheduleAttentionRefresh()
        }
        scheduleRuntimeNotificationObservation()
    }

    private func scheduleRuntimeBootstrap() {
        let model = self
        let generation = UUID()
        runtimeBootstrapGeneration = generation
        runtimeBootstrapTask?.cancel()
        runtimeBootstrapTask = Task { [runtimeService] in
            model.runtimeBootstrapState = runtimeService.managesPersistentRuns ? .reconciling : .ready
            await runtimeService.setEventSink { projectID, state in
                Task { @MainActor [weak model] in
                    model?.receiveRuntime(projectID: projectID, state: state)
                }
            }
            let report = await runtimeService.reconcile(projects: model.projects)
            let snapshots = await runtimeService.allSnapshots()
            guard !Task.isCancelled,
                  model.runtimeBootstrapGeneration == generation,
                  !model.isShuttingDown else { return }
            for (projectID, state) in snapshots {
                model.receiveRuntime(projectID: projectID, state: state)
            }
            model.runtimeReconciliationReport = report
            model.scheduleAttentionRefresh(immediate: true)
            if let ledgerError = report.ledgerError {
                model.runtimeBootstrapState = .blocked(ledgerError)
                model.errorMessage = ledgerError
                return
            }
            model.runtimeBootstrapState = .ready
            await model.autostartAfterReconciliation(bootstrapGeneration: generation)
            if model.runtimeBootstrapGeneration == generation {
                model.runtimeBootstrapTask = nil
            }
        }
    }

    private func autostartAfterReconciliation(bootstrapGeneration: UUID) async {
        guard !Task.isCancelled,
              runtimeBootstrapGeneration == bootstrapGeneration,
              !isShuttingDown,
              !isWorkspaceOperating else { return }
        let ids = projects.filter {
            $0.autostart
                && !runtime(for: $0.id).status.isActive
                && !runtime(for: $0.id).ownership.hasUnresolvedRun
        }.map(\.id)
        guard !ids.isEmpty else { return }
        let profile = WorkspaceProfile(
            id: "__localwrap_internal_autostart__",
            name: "Automatic startup",
            projectIds: ids,
            createdAt: "", updatedAt: "", lastStartedAt: nil, source: nil
        )
        var launchWorkspace = workspace
        launchWorkspace.savedWorkspaces.removeAll { $0.id == profile.id }
        launchWorkspace.savedWorkspaces.append(profile)
        let operationGeneration = UUID()
        workspaceOperationGeneration = operationGeneration
        isWorkspaceOperating = true
        defer {
            if workspaceOperationGeneration == operationGeneration {
                isWorkspaceOperating = false
            }
        }
        do {
            let (diagnosis, operation) = try await workspaceOrchestration.start(
                projects: projects,
                workspace: launchWorkspace,
                target: .profile(profile.id),
                startReadyOnly: false
            )
            guard workspaceOperationGeneration == operationGeneration,
                  runtimeBootstrapGeneration == bootstrapGeneration,
                  !isShuttingDown else { return }
            workspaceDiagnosis = diagnosis
            workspaceOperation = operation.bound(to: .allProjects)
            retainWorkspaceOperation(operation, target: .allProjects)
            scheduleAttentionRefresh()
        } catch {
            guard workspaceOperationGeneration == operationGeneration,
                  runtimeBootstrapGeneration == bootstrapGeneration,
                  !isShuttingDown else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleRunHistoryLoad() {
        guard let runHistoryCoordinator else { return }
        let previousTask = runHistoryTask
        runHistoryTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let document = try await runHistoryCoordinator.load()
                guard let self else { return }
                self.runHistoryDocument = document
                self.runHistoryErrorMessage = nil
            } catch {
                self?.runHistoryErrorMessage = error.localizedDescription
            }
        }
    }

    private func captureRunHistory(
        projectID: String,
        previous: RuntimeSnapshot?,
        current: RuntimeSnapshot
    ) {
        guard runHistoryCoordinator != nil else { return }
        let existing = runHistoryCaptures[projectID]
        let hasRunEvidence = current.runID != nil
            || current.startedAt != nil
            || current.terminalReason != nil
            || current.status != .stopped
            || previous?.status.isActive == true
        guard hasRunEvidence else { return }

        let timestamp = runHistoryTimestamp(for: current)
        let runID = current.runID
            ?? previous?.runID
            ?? existing?.runID
            ?? "session:\(projectID):\(current.startedAt ?? timestamp)"
        var capture = existing?.runID == runID
            ? existing!
            : RunHistoryCapture(
                runID: runID,
                projectID: projectID,
                startedAt: current.startedAt ?? timestamp,
                endedAt: nil,
                finalState: runHistoryState(for: current),
                exitCode: nil,
                transitions: [],
                lifecycleExcerpt: []
            )
        let before = capture
        let state = runHistoryState(for: current)
        if capture.transitions.last?.state != state {
            capture.transitions.append(RunHistoryTransitionInput(at: timestamp, state: state))
            capture.transitions = Array(capture.transitions.suffix(
                RunHistoryRecord.maximumTransitions
            ))
        }
        for event in runHistoryLifecycleEvents(from: previous, to: current) {
            guard capture.lifecycleExcerpt.last?.event != event else { continue }
            capture.lifecycleExcerpt.append(RunHistoryLifecycleInput(at: timestamp, event: event))
        }
        capture.lifecycleExcerpt = Array(capture.lifecycleExcerpt.suffix(
            RunHistoryRecord.maximumLifecycleEntries
        ))
        capture.finalState = state
        capture.exitCode = current.exitCode
        if !current.status.isActive {
            capture.endedAt = current.stoppedAt ?? timestamp
        }

        runHistoryCaptures[projectID] = capture
        guard capture != before else { return }
        enqueueRunHistory(capture.draft)
    }

    private func enqueueRunHistory(_ draft: RunHistoryDraft) {
        guard let runHistoryCoordinator else { return }
        let previousTask = runHistoryTask
        runHistoryTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let document = try await runHistoryCoordinator.record(draft)
                guard let self else { return }
                self.runHistoryDocument = document
                self.runHistoryErrorMessage = nil
            } catch {
                self?.runHistoryErrorMessage = error.localizedDescription
            }
        }
    }

    private func runHistoryTimestamp(for snapshot: RuntimeSnapshot) -> String {
        switch snapshot.status {
        case .ready:
            snapshot.readyAt ?? snapshot.startedAt ?? diagnosticNow()
        case .stopped, .failed:
            snapshot.stoppedAt ?? snapshot.readyAt ?? snapshot.startedAt ?? diagnosticNow()
        case .starting, .runningUnresponsive, .stopping:
            snapshot.startedAt ?? diagnosticNow()
        }
    }

    private func runHistoryState(for snapshot: RuntimeSnapshot) -> RunHistoryState {
        switch snapshot.ownership {
        case .conflicting:
            return .ownershipConflict
        case .unverifiable:
            return .ownershipUnverifiable
        case .none, .reconciling, .verified:
            break
        }
        if case .unexpectedExit = snapshot.terminalReason { return .exited }
        return switch snapshot.status {
        case .stopped: .stopped
        case .starting: .starting
        case .ready: .ready
        case .runningUnresponsive: .unresponsive
        case .stopping: .stopping
        case .failed: .failed
        }
    }

    private func runHistoryLifecycleEvents(
        from previous: RuntimeSnapshot?,
        to current: RuntimeSnapshot
    ) -> [RunHistoryLifecycleEvent] {
        var events: [RunHistoryLifecycleEvent] = []
        if previous == nil, current.recoveredAfterRelaunch {
            events.append(.reconciliationRecovered)
        }
        if previous?.ownership != current.ownership {
            switch current.ownership {
            case .reconciling:
                events.append(.reconciliationStarted)
            case .verified where current.recoveredAfterRelaunch:
                events.append(.reconciliationRecovered)
            case .unverifiable, .conflicting:
                events.append(.reconciliationBlocked)
            case .none, .verified:
                break
            }
        }
        if previous?.status != current.status {
            switch current.status {
            case .starting:
                events.append(.launchRequested)
            case .ready:
                events.append(.readinessPassed)
            case .stopping:
                events.append(.stopRequested)
            case .stopped, .failed, .runningUnresponsive:
                break
            }
        }
        if current.pid != nil, previous?.pid != current.pid {
            events.append(.processStarted)
        }
        if previous?.terminalReason != current.terminalReason {
            switch current.terminalReason {
            case .readinessTimeout:
                events.append(.readinessTimedOut)
            case .launchFailure, .doctorBlocked:
                events.append(.launchFailed)
            case .unexpectedExit, .intentionalStop, .cleanupFailure:
                events.append(.processExited)
            case .ownershipConflict, .ownershipUnverifiable:
                events.append(.reconciliationBlocked)
            case nil:
                break
            }
        }
        var seen = Set<RunHistoryLifecycleEvent>()
        return events.filter { seen.insert($0).inserted }
    }

    private func retainWorkspaceOperation(
        _ operation: WorkspaceOperationSummary,
        target: WorkspaceTarget
    ) {
        var unresolvedByProject = Dictionary(uniqueKeysWithValues:
            (retainedWorkspaceOperations[target]?.unresolvedResults ?? [])
                .map { ($0.projectID, $0) }
        )
        for result in operation.results {
            if result.requiresAttention {
                unresolvedByProject[result.projectID] = result
            } else {
                unresolvedByProject[result.projectID] = nil
            }
        }

        let bounded = Array(unresolvedByProject.values
            .sorted { $0.projectID < $1.projectID }
            .prefix(32))
        retainedWorkspaceOperationOrder.removeAll { $0 == target }
        if bounded.isEmpty {
            retainedWorkspaceOperations[target] = nil
            return
        }

        retainedWorkspaceOperations[target] = WorkspaceOperationSummary(
            results: bounded,
            target: target
        )
        retainedWorkspaceOperationOrder.append(target)
        while retainedWorkspaceOperationOrder.count > 8 {
            let removed = retainedWorkspaceOperationOrder.removeFirst()
            retainedWorkspaceOperations[removed] = nil
        }
    }

    private func resolveRetainedWorkspaceOperations(projectID: String) -> Bool {
        var changed = false
        for target in retainedWorkspaceOperationOrder {
            guard let operation = retainedWorkspaceOperations[target],
                  operation.unresolvedResults.contains(where: { $0.projectID == projectID }) else {
                continue
            }
            retainedWorkspaceOperations[target] = operation.resolvingAttention(for: projectID)
            changed = true
        }
        retainedWorkspaceOperationOrder.removeAll {
            retainedWorkspaceOperations[$0] == nil
        }
        return changed
    }

    private func pruneRetainedWorkspaceOperations(projectIDs: Set<String>) {
        let profileIDs = Set(workspace.savedWorkspaces.map(\.id))
        for target in retainedWorkspaceOperationOrder {
            if case .profile(let profileID) = target, !profileIDs.contains(profileID) {
                retainedWorkspaceOperations[target] = nil
                continue
            }
            guard let operation = retainedWorkspaceOperations[target] else { continue }
            let remaining = operation.unresolvedResults.filter {
                projectIDs.contains($0.projectID)
            }
            retainedWorkspaceOperations[target] = remaining.isEmpty
                ? nil
                : WorkspaceOperationSummary(results: remaining, target: target)
        }
        retainedWorkspaceOperationOrder.removeAll {
            retainedWorkspaceOperations[$0] == nil
        }
    }

    private func scheduleAttentionRefresh(immediate: Bool = false) {
        guard !isShuttingDown else { return }
        let previousRefreshTask = attentionRefreshTask
        let previousDiagnosisTask = attentionDiagnosisTask
        previousRefreshTask?.cancel()
        previousDiagnosisTask?.cancel()
        attentionDiagnosisTask = nil
        let generation = UUID()
        attentionRefreshGeneration = generation
        attentionRefreshRevision &+= 1
        let revision = attentionRefreshRevision

        let projectsSnapshot = projects
        let runtimesSnapshot = runtimes
        let workspaceSnapshot = workspace
        let previewSnapshot = previewFailures
        let reconciliationSnapshot = runtimeReconciliationReport
        let operationSnapshots = retainedWorkspaceOperationOrder.compactMap {
            retainedWorkspaceOperations[$0]
        }
        let doctor = doctorService
        let workspaceDoctor = workspaceDoctor
        let service = attentionService

        attentionRefreshTask = Task { @MainActor [weak self] in
            // A cancelled detached diagnosis cannot be force-stopped while it is
            // inside a synchronous filesystem check. Wait for it to observe
            // cancellation before starting the replacement so batches never
            // overlap and rapid state changes coalesce deterministically.
            if let previousRefreshTask {
                await previousRefreshTask.value
            }
            guard !Task.isCancelled,
                  let self,
                  self.attentionRefreshGeneration == generation,
                  !self.isShuttingDown else { return }

            if !immediate {
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  self.attentionRefreshGeneration == generation,
                  !self.isShuttingDown else { return }

            let diagnosisTask = Task.detached(priority: .utility) {
                () -> AttentionRefreshPayload? in
                guard !Task.isCancelled else { return nil }
                let boundedProjects = Array(
                    projectsSnapshot.prefix(AttentionService.maximumProjects)
                )
                let knownProjectIDs = Set(boundedProjects.map(\.id))
                let attentionRuntimes = runtimesSnapshot.filter {
                    knownProjectIDs.contains($0.key) || $0.value.ownership.hasUnresolvedRun
                }
                guard !Task.isCancelled else { return nil }

                var diagnoses: [String: ProjectDiagnosis] = [:]
                var projectPolicies: [String: MenuProjectValidatedPolicy] = [:]
                diagnoses.reserveCapacity(boundedProjects.count)
                projectPolicies.reserveCapacity(boundedProjects.count)
                for project in boundedProjects {
                    guard !Task.isCancelled else { return nil }
                    let runtime = runtimesSnapshot[project.id] ?? RuntimeSnapshot()
                    let runtimeDiagnosis = runtime.diagnosis
                    let diagnosis = (runtime.status.isActive || runtime.ownership.hasUnresolvedRun)
                        && runtimeDiagnosis.hasConfigurationCheck
                        ? runtimeDiagnosis
                        : doctor.diagnose(ProjectDraft(project: project))
                    guard !Task.isCancelled else { return nil }
                    diagnoses[project.id] = diagnosis
                    projectPolicies[project.id] = makeMenuProjectPolicy(
                        project: project,
                        runtime: runtime,
                        diagnosis: diagnosis
                    )
                }

                guard !Task.isCancelled else { return nil }
                var requestedTargets: [(WorkspaceTarget, [String])] = [
                    (.allProjects, boundedProjects.map(\.id)),
                ]
                let lastRunningIDs = workspaceSnapshot.lastRunningProjectIds.filter {
                    knownProjectIDs.contains($0)
                }
                if !workspaceSnapshot.lastRunningProjectIds.isEmpty {
                    requestedTargets.append((.lastRunning, lastRunningIDs))
                }
                for profile in MenuCommandCenterService.profilesRequiringPolicy(
                    workspaceSnapshot.savedWorkspaces
                ) {
                    requestedTargets.append((
                        .profile(profile.id),
                        profile.projectIds.filter { knownProjectIDs.contains($0) }
                    ))
                }

                var workspaceDiagnoses: [WorkspaceDiagnosis] = []
                var workspacePolicies: [WorkspaceTarget: MenuWorkspaceValidatedPolicy] = [:]
                for (target, expectedProjectIDs) in requestedTargets {
                    guard !Task.isCancelled else { return nil }
                    do {
                        let diagnosis = try workspaceDoctor.diagnose(
                            projects: boundedProjects,
                            workspace: workspaceSnapshot,
                            target: target,
                            runtimes: runtimesSnapshot
                        )
                        if target == .allProjects {
                            workspaceDiagnoses = [diagnosis]
                        }
                        workspacePolicies[target] = makeMenuWorkspacePolicy(
                            target: target,
                            expectedProjectIDs: expectedProjectIDs,
                            diagnosis: diagnosis
                        )
                    } catch {
                        workspacePolicies[target] = MenuWorkspaceValidatedPolicy(
                            target: target,
                            projectIDs: expectedProjectIDs,
                            validation: .blocked(.validationPending)
                        )
                    }
                }
                guard !Task.isCancelled else { return nil }

                return AttentionRefreshPayload(
                    attention: AttentionInput(
                        projects: boundedProjects,
                        runtimes: attentionRuntimes,
                        projectDiagnoses: diagnoses,
                        workspaceDiagnoses: workspaceDiagnoses,
                        workspaceOperations: operationSnapshots,
                        previews: previewSnapshot,
                        runtimeReconciliation: reconciliationSnapshot
                    ),
                    projectPolicies: projectPolicies,
                    workspacePolicies: workspacePolicies
                )
            }
            self.attentionDiagnosisTask = diagnosisTask
            guard let payload = await diagnosisTask.value else {
                if self.attentionRefreshGeneration == generation {
                    self.attentionDiagnosisTask = nil
                }
                return
            }
            if self.attentionRefreshGeneration == generation {
                self.attentionDiagnosisTask = nil
            }

            guard !Task.isCancelled,
                  self.attentionRefreshGeneration == generation,
                  !self.isShuttingDown else { return }
            let snapshot = await service.update(payload.attention, revision: revision)
            guard !Task.isCancelled,
                  self.attentionRefreshGeneration == generation,
                  !self.isShuttingDown else { return }
            self.attentionSnapshot = snapshot
            self.menuProjectPolicies = payload.projectPolicies
            self.menuWorkspacePolicies = payload.workspacePolicies
        }
    }

    private func runtimeAttentionChanged(
        from previous: RuntimeSnapshot?,
        to current: RuntimeSnapshot
    ) -> Bool {
        guard let previous else { return true }
        return previous.status != current.status
            || previous.ownership != current.ownership
            || previous.terminalReason != current.terminalReason
            || previous.diagnosis != current.diagnosis
    }

    private func captureActiveProjectIDs(fallback: [String] = []) throws {
        guard let store else { return }
        let active = projects.map(\.id).filter { runtimes[$0]?.status.isActive == true }
        workspace = try store.setLastRunningProjectIDs(active.isEmpty ? fallback : active)
        workspaceCount = workspace.savedWorkspaces.count
    }

    private var runtimeBootstrapMessage: String {
        switch runtimeBootstrapState {
        case .ready:
            "Runtime reconciliation is ready."
        case .reconciling:
            "Wait for LocalWrap to finish reconciling previously launched processes."
        case .blocked(let message):
            message
        }
    }

    private func requireRuntimeBootstrap() throws {
        guard runtimeControlsAvailable else {
            throw RuntimeError.reconciliationRequired(runtimeBootstrapMessage)
        }
    }
}

private func makeMenuProjectPolicy(
    project: Project,
    runtime: RuntimeSnapshot,
    diagnosis: ProjectDiagnosis
) -> MenuProjectValidatedPolicy {
    let configuration: MenuProjectConfigurationPolicy
    if let failure = diagnosis.validation.errors.first {
        configuration = .invalid(firstFailureField: failure.field)
    } else if let failedCheck = diagnosis.checks.first(where: { $0.status == .fail }),
              let field = menuProjectField(for: failedCheck.id) {
        configuration = .invalid(firstFailureField: field)
    } else {
        configuration = .valid
    }

    let signalling: MenuRuntimeSignallingCapability
    switch runtime.ownership {
    case .none:
        signalling = .unavailable(.noOwnedProcess)
    case .reconciling:
        signalling = .unavailable(.reconciling)
    case .verified(let runID):
        signalling = runtime.runID == runID
            ? .verified(runID: runID)
            : .unavailable(.runIdentityChanged)
    case .unverifiable:
        signalling = .unavailable(.ownershipUnverifiable)
    case .conflicting:
        signalling = .unavailable(.ownershipConflict)
    }

    return MenuProjectValidatedPolicy(
        projectID: project.id,
        configuration: configuration,
        canOpenValidatedLocalURL: LocalURLValidator().url(from: project.url) != nil,
        signalling: signalling
    )
}

private func makeMenuWorkspacePolicy(
    target: WorkspaceTarget,
    expectedProjectIDs: [String],
    diagnosis: WorkspaceDiagnosis
) -> MenuWorkspaceValidatedPolicy {
    let validation: MenuWorkspaceValidationState
    if Set(diagnosis.target.projectIDs) != Set(expectedProjectIDs) {
        validation = .blocked(.validationPending)
    } else {
        switch diagnosis.status {
        case .empty:
            validation = .blocked(.noProjects)
        case .ready, .attention:
            validation = .ready
        case .blocked:
            let reason = diagnosis.checks
                .first(where: { $0.status == .fail })
                .map { menuWorkspaceBlockReason(for: $0.id) }
                ?? .configuration
            validation = .blocked(reason)
        }
    }
    return MenuWorkspaceValidatedPolicy(
        target: target,
        projectIDs: expectedProjectIDs,
        validation: validation
    )
}

private func menuProjectField(for check: DoctorCheckID) -> ProjectField? {
    switch check {
    case .directory: .cwd
    case .command: .command
    case .dependencies: .dependencies
    case .port: .port
    case .url: .url
    case .process, .readiness: nil
    }
}

private func menuWorkspaceBlockReason(
    for check: WorkspaceCheckID
) -> MenuWorkspaceValidationBlockReason {
    switch check {
    case .projects, .directories, .commands: .configuration
    case .startup, .dependencies: .dependencies
    case .environment: .environment
    case .ports: .ports
    case .urls: .urls
    }
}

private struct RunHistoryCapture: Equatable, Sendable {
    let runID: String
    let projectID: String
    let startedAt: String
    var endedAt: String?
    var finalState: RunHistoryState
    var exitCode: Int32?
    var transitions: [RunHistoryTransitionInput]
    var lifecycleExcerpt: [RunHistoryLifecycleInput]

    var draft: RunHistoryDraft {
        RunHistoryDraft(
            runID: runID,
            projectID: projectID,
            startedAt: startedAt,
            endedAt: endedAt,
            finalState: finalState,
            exitCode: exitCode,
            transitions: transitions,
            lifecycleExcerpt: lifecycleExcerpt
        )
    }
}

enum PersistenceStatus: Equatable {
    case notLoaded
    case ready(MigrationResult.Outcome)
    case recoveryRequired(message: String, backupAvailable: Bool)
}
