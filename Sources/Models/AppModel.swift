import Foundation
import Observation

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
    private(set) var isWorkspaceOperating: Bool
    private(set) var isCheckingForUpdates: Bool
    var releaseNotice: ReleaseNotice?
    var selectedWorkspaceTarget: WorkspaceTarget?
    var errorMessage: String?
    private(set) var repositoryOpenProposal: RepositoryOpenProposal?

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
    private let releaseChecker: ReleaseCheckService
    private let currentVersion: @Sendable () -> String
    private let sampleService: SampleProjectService
    private let sampleDestination: @Sendable () -> URL
    private let directoryPicker: DirectoryPickerService
    private let repositoryOnboarding: RepositoryOnboardingService
    private var openedReadyRunIDs: Set<String>

    init(
        projectCount: Int = 0,
        workspaceCount: Int = 0,
        runningProjectCount: Int = 0,
        persistenceStatus: PersistenceStatus = .notLoaded,
        projects: [Project] = [],
        workspace: WorkspaceState = .empty,
        initialRuntimes: [String: RuntimeSnapshot] = [:],
        store: ProjectStore? = nil,
        runtimeService: RuntimeService = RuntimeService(),
        doctorService: ProjectDoctorService = ProjectDoctorService(),
        reportBuilder: DoctorReportBuilder = DoctorReportBuilder(),
        desktopActions: DesktopActionService = .live,
        workspaceDoctor: WorkspaceDoctorService = WorkspaceDoctorService(),
        workspaceOrchestration: WorkspaceOrchestrationService? = nil,
        workspacePacks: WorkspacePackService = WorkspacePackService(),
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
        repositoryOpenProposal: RepositoryOpenProposal? = nil
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
        self.releaseChecker = releaseChecker
        self.currentVersion = currentVersion
        self.sampleService = sampleService
        self.sampleDestination = sampleDestination
        self.directoryPicker = directoryPicker
        self.repositoryOnboarding = repositoryOnboarding
            ?? RepositoryOnboardingService(workspacePacks: workspacePacks)
        self.repositoryOpenProposal = repositoryOpenProposal
            ?? repositoryProposal.map(RepositoryOpenProposal.project)
        openedReadyRunIDs = []
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
                store: store,
                runtimeService: runtimeService,
                doctorService: doctorService,
                reportBuilder: reportBuilder,
                desktopActions: desktopActions,
                workspaceDoctor: workspaceDoctor,
                workspaceOrchestration: workspaceOrchestration,
                workspacePacks: workspacePacks,
                releaseChecker: releaseChecker,
                currentVersion: currentVersion
            )
            model.connectRuntimeEvents()
            model.scheduleAutostart()
            return model
        } catch {
            return AppModel(
                persistenceStatus: .recoveryRequired(
                    message: error.localizedDescription,
                    backupAvailable: store.hasBackup()
                ),
                store: store,
                runtimeService: runtimeService,
                doctorService: doctorService,
                reportBuilder: reportBuilder,
                desktopActions: desktopActions,
                workspaceDoctor: workspaceDoctor,
                workspaceOrchestration: workspaceOrchestration,
                workspacePacks: workspacePacks,
                releaseChecker: releaseChecker,
                currentVersion: currentVersion
            )
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
                        readinessMessage: "Ready for preview."
                    ),
                ]
            )
        }
        #endif
        return live()
    }

    var menuStatusSummary: String {
        MenuStatusFormatter.summary(running: runningProjectCount, saved: projectCount)
    }

    var readyProjects: [Project] {
        projects.filter { runtime(for: $0.id).status == .ready }
    }

    var activeProjects: [Project] {
        projects.filter { runtime(for: $0.id).status.isActive }
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
                let runtime = existingID.map { self.runtime(for: $0) } ?? RuntimeSnapshot()
                let reportProject = existingID
                    .flatMap { project(id: $0) }
                    .map(ProjectDraft.init(project:)) ?? draft
                desktopActions.copyText(reportBuilder.build(
                    project: reportProject,
                    runtime: runtime,
                    diagnosis: diagnosis
                ))
                return draft
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
            connectRuntimeEvents()
            scheduleAutostart()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startProject(id: String) async throws {
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
        let state = await runtimeService.stop(projectID: id)
        receiveRuntime(projectID: id, state: state)
    }

    func restartProject(id: String) async throws {
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
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startWorkspace(target: WorkspaceTarget? = nil, readyOnly: Bool) async {
        guard !isWorkspaceOperating else { return }
        isWorkspaceOperating = true
        selectedWorkspaceTarget = target
        defer { isWorkspaceOperating = false }
        do {
            let (diagnosis, operation) = try await workspaceOrchestration.start(
                projects: projects,
                workspace: workspace,
                target: target,
                startReadyOnly: readyOnly
            )
            workspaceDiagnosis = diagnosis
            workspaceOperation = operation
            if let profileID = diagnosis.target.profileID {
                _ = try store?.markWorkspaceStarted(id: profileID)
            }
            try captureActiveProjectIDs(fallback: operation.results
                .filter { $0.status == .started || $0.reason == "already-active" }
                .map(\.projectID))
            try reloadPersistence()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopAllProjects() async {
        do { try captureActiveProjectIDs() }
        catch { errorMessage = error.localizedDescription }
        isWorkspaceOperating = true
        await workspaceOrchestration.stopAll()
        isWorkspaceOperating = false
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
            _ = try workspacePacks.importReviewed(review, into: store)
            try reloadPersistence()
            selectedWorkspaceTarget = .allProjects
            workspaceDiagnosis = try workspaceDoctor.diagnose(
                projects: projects,
                workspace: workspace,
                target: selectedWorkspaceTarget,
                runtimes: runtimes
            )
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
                  runtime(for: projectID).status.isActive else { return nil }
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

    func shutdown() async {
        try? captureActiveProjectIDs()
        await workspaceOrchestration.stopAll()
    }

    private func reloadPersistence() throws {
        guard let store else { return }
        let document = try store.load()
        projects = document.projects
        workspace = document.workspace
        projectCount = projects.count
        workspaceCount = workspace.savedWorkspaces.count
    }

    private func openValidatedLocalURL(_ value: String) {
        guard let url = LocalURLValidator().url(from: value) else { return }
        desktopActions.openURL(url)
    }

    private func guardActiveProjectMutation(id: String, draft: ProjectDraft) throws {
        guard runtime(for: id).status.isActive, let saved = project(id: id) else { return }
        if saved.cwd != draft.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            || saved.command != draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
            || saved.port != draft.port
            || saved.url != draft.url.trimmingCharacters(in: .whitespacesAndNewlines) {
            throw DoctorError.activeProject
        }
    }

    private func connectRuntimeEvents() {
        let model = self
        Task { [runtimeService] in
            await runtimeService.setEventSink { projectID, state in
                Task { @MainActor [weak model] in
                    model?.receiveRuntime(projectID: projectID, state: state)
                }
            }
        }
    }

    private func receiveRuntime(projectID: String, state: RuntimeSnapshot) {
        let previousStatus = runtimes[projectID]?.status ?? .stopped
        runtimes[projectID] = state
        runningProjectCount = runtimes.values.count { $0.status.isActive }
        if state.status == .ready,
           previousStatus != .ready,
           !openedReadyRunIDs.contains(projectID),
           let project = project(id: projectID), project.openOnReady {
            openedReadyRunIDs.insert(projectID)
            openValidatedLocalURL(project.url)
        } else if !state.status.isActive {
            openedReadyRunIDs.remove(projectID)
        }
    }

    private func scheduleAutostart() {
        let ids = projects.filter(\.autostart).map(\.id)
        guard !ids.isEmpty else { return }
        let profile = WorkspaceProfile(
            id: "native-autostart", name: "Automatic startup", projectIds: ids,
            createdAt: "", updatedAt: "", lastStartedAt: nil, source: nil
        )
        var launchWorkspace = workspace
        launchWorkspace.savedWorkspaces.append(profile)
        let model = self
        Task { [workspaceOrchestration, projects, runtimes] in
            do {
                let (diagnosis, operation) = try await workspaceOrchestration.start(
                    projects: projects,
                    workspace: launchWorkspace,
                    target: .profile(profile.id),
                    startReadyOnly: false
                )
                await MainActor.run {
                    guard !model.isWorkspaceOperating else { return }
                    model.workspaceDiagnosis = diagnosis
                    model.workspaceOperation = operation
                }
            } catch {
                await MainActor.run { model.errorMessage = error.localizedDescription }
            }
            _ = runtimes
        }
    }

    private func captureActiveProjectIDs(fallback: [String] = []) throws {
        guard let store else { return }
        let active = projects.map(\.id).filter { runtimes[$0]?.status.isActive == true }
        _ = try store.setLastRunningProjectIDs(active.isEmpty ? fallback : active)
    }
}

enum PersistenceStatus: Equatable {
    case notLoaded
    case ready(MigrationResult.Outcome)
    case recoveryRequired(message: String, backupAvailable: Bool)
}
