import Foundation
import XCTest
@testable import LocalWrapMac

@MainActor
final class AppModelTests: XCTestCase {
    func testInitialAppModelIsEmpty() {
        let model = AppModel()

        XCTAssertEqual(model.projectCount, 0)
        XCTAssertEqual(model.workspaceCount, 0)
        XCTAssertEqual(model.runningProjectCount, 0)
        XCTAssertEqual(model.menuStatusSummary, "0 running / 0 saved")
    }

    func testInitialSelectionIsWelcome() {
        XCTAssertEqual(AppSelection.initial, .welcome)
        XCTAssertEqual(AppModel().navigationRouter.selection, .welcome)
    }

    func testRuntimeMutationsFailClosedUntilReconciliationCompletes() async {
        let project = Project(
            id: "web",
            name: "Web",
            cwd: "/tmp",
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000",
            createdAt: "2026-07-19T00:00:00Z",
            updatedAt: "2026-07-19T00:00:00Z"
        )
        let model = AppModel(
            projects: [project],
            runtimeBootstrapState: .reconciling
        )

        XCTAssertFalse(model.runtimeControlsAvailable)
        do {
            try await model.startProject(id: project.id)
            XCTFail("Start must wait for runtime reconciliation.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeError,
                .reconciliationRequired(
                    "Wait for LocalWrap to finish reconciling previously launched processes."
                )
            )
        }

        await model.stopProject(id: project.id)
        XCTAssertEqual(
            model.errorMessage,
            "Wait for LocalWrap to finish reconciling previously launched processes."
        )
    }

    func testLiveModelRestoresLastStableSelection() throws {
        let fixture = try makeFixture(name: "SessionRestore")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = try fixture.store.createProject(ProjectDraft(
            name: "Demo",
            cwd: fixture.projectDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000"
        ))
        let sessionStore = SessionStateStore(
            fileURL: fixture.root.appendingPathComponent("session.json")
        )
        try sessionStore.save(.project(project.id))

        let model = AppModel.live(store: fixture.store, sessionStore: sessionStore)

        XCTAssertEqual(model.navigationRouter.selection, .project(project.id))
    }

    func testAutostartWaitsForReconciliationAndDoesNotDuplicateRecoveredRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelBootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveredDirectory = root.appendingPathComponent("recovered", isDirectory: true)
        let freshDirectory = root.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveredDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshDirectory, withIntermediateDirectories: true)
        let ids = AppModelIDSequence(["recovered", "fresh"])
        let store = ProjectStore(
            paths: ProjectStorePaths(
                directory: root,
                store: root.appendingPathComponent("store.json"),
                backup: root.appendingPathComponent("store.json.bak"),
                electronStore: root.appendingPathComponent("electron.json")
            ),
            now: { "2026-07-19T00:00:00Z" },
            makeID: ids.next
        )
        let recovered = try store.createProject(ProjectDraft(
            name: "Recovered",
            cwd: recoveredDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000",
            autostart: true
        ))
        let fresh = try store.createProject(ProjectDraft(
            name: "Fresh",
            cwd: freshDirectory.path,
            command: "npm start",
            port: 3_001,
            url: "http://localhost:3001",
            autostart: true
        ))
        let record = AppModelManagedRuntimeFixtures.record(for: recovered)
        let ledger = AppModelManagedLedger(records: [record])
        let inspector = AppModelGatedInspector()
        let launcher = AppModelManagedLauncher()
        let doctor = ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: { _ in true }),
            now: { "2026-07-19T00:00:00Z" }
        )
        let runtime = RuntimeService(
            environmentResolver: EnvironmentResolver(
                environment: { ["PATH": "/tools"] },
                isExecutable: { $0 == "/tools/npm" }
            ),
            launcher: launcher,
            ledgerStore: ledger,
            processInspector: inspector,
            readiness: AppModelImmediateReadiness(),
            doctor: doctor,
            now: { "2026-07-19T00:00:00Z" },
            isDirectory: { _ in true }
        )
        let orchestration = WorkspaceOrchestrationService(
            runtime: runtime,
            doctor: WorkspaceDoctorService(
                projectDoctor: doctor,
                portSuggester: PortSuggestionService(isAvailable: { _ in true })
            )
        )

        let model = AppModel.live(
            store: store,
            runtimeService: runtime,
            doctorService: doctor,
            workspaceOrchestration: orchestration
        )
        for _ in 0..<500 where !inspector.reconciliationStarted {
            await Task.yield()
        }

        XCTAssertTrue(inspector.reconciliationStarted)
        XCTAssertEqual(launcher.prepareCount, 0)
        XCTAssertEqual(launcher.monitorCount, 0)
        XCTAssertEqual(model.runtimeBootstrapState, .reconciling)

        inspector.finishReconciliation()
        for _ in 0..<500 {
            if model.runtimeBootstrapState == .ready,
               launcher.prepareCount == 1,
               launcher.monitorCount == 1,
               model.runtime(for: fresh.id).status == .ready {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(model.runtimeBootstrapState, .ready)
        XCTAssertEqual(launcher.monitorCount, 1)
        XCTAssertEqual(launcher.prepareCount, 1)
        XCTAssertTrue(model.runtime(for: recovered.id).recoveredAfterRelaunch)
        XCTAssertEqual(model.runtime(for: recovered.id).ownership, .verified(runID: record.runID))
        XCTAssertEqual(model.runtime(for: fresh.id).status, .ready)
    }

    func testShutdownCancelsBootstrapBeforeAutostartCanPrepareALaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelShutdownBootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let store = ProjectStore(
            paths: ProjectStorePaths(
                directory: root,
                store: root.appendingPathComponent("store.json"),
                backup: root.appendingPathComponent("store.json.bak"),
                electronStore: root.appendingPathComponent("electron.json")
            ),
            now: { "2026-07-19T00:00:00Z" },
            makeID: { "autostart" }
        )
        let project = try store.createProject(ProjectDraft(
            name: "Autostart",
            cwd: projectDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000",
            autostart: true
        ))
        let ledger = AppModelManagedLedger(records: [
            AppModelManagedRuntimeFixtures.record(for: project),
        ])
        let inspector = AppModelGatedExitedInspector()
        let launcher = AppModelManagedLauncher()
        let doctor = ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: { _ in true }),
            now: { "2026-07-19T00:00:00Z" }
        )
        let runtime = RuntimeService(
            environmentResolver: EnvironmentResolver(
                environment: { ["PATH": "/tools"] },
                isExecutable: { $0 == "/tools/npm" }
            ),
            launcher: launcher,
            ledgerStore: ledger,
            processInspector: inspector,
            readiness: AppModelImmediateReadiness(),
            doctor: doctor,
            now: { "2026-07-19T00:00:00Z" },
            isDirectory: { _ in true }
        )
        let model = AppModel.live(
            store: store,
            runtimeService: runtime,
            doctorService: doctor,
            workspaceOrchestration: WorkspaceOrchestrationService(
                runtime: runtime,
                doctor: WorkspaceDoctorService(
                    projectDoctor: doctor,
                    portSuggester: PortSuggestionService(isAvailable: { _ in true })
                )
            )
        )
        for _ in 0..<500 where !inspector.reconciliationStarted {
            await Task.yield()
        }
        XCTAssertTrue(inspector.reconciliationStarted)

        let shutdown = Task { await model.shutdown() }
        for _ in 0..<10 { await Task.yield() }
        inspector.finishReconciliation()
        let report = await shutdown.value
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(report.canTerminate)
        XCTAssertEqual(launcher.prepareCount, 0)
        XCTAssertEqual(launcher.monitorCount, 0)
    }

    func testMenuStatusIsBoundedAndNormalizesCounts() {
        XCTAssertEqual(
            MenuStatusFormatter.summary(running: 10_000, saved: -1),
            "999+ running / 0 saved"
        )
        XCTAssertLessThanOrEqual(
            MenuStatusFormatter.summary(running: .max, saved: .max).count,
            30
        )
    }

    func testCancellingRepositoryPickerDoesNotCreateAProposalOrProject() {
        let model = AppModel(directoryPicker: DirectoryPickerService(chooseRepository: { nil }))

        model.chooseRepository()

        XCTAssertNil(model.repositoryProposal)
        XCTAssertTrue(model.projects.isEmpty)
    }

    func testChoosingRepositoryCreatesReviewProposalWithoutPersistence() throws {
        let fixture = try makeFixture(name: "RepositoryPicker")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = AppModel(
            directoryPicker: DirectoryPickerService(
                chooseRepository: { fixture.projectDirectory }
            ),
            repositoryOnboarding: RepositoryOnboardingService(
                inspector: ProjectInspectionService(
                    portSuggester: PortSuggestionService { _ in true }
                )
            )
        )

        model.chooseRepository()

        XCTAssertEqual(model.repositoryProposal?.rootURL.path, fixture.projectDirectory.path)
        XCTAssertEqual(model.repositoryProposal?.draft.command, "npm start")
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(try fixture.store.listProjects(), [])

        model.dismissRepositoryProposal()

        XCTAssertNil(model.repositoryProposal)
        XCTAssertEqual(try fixture.store.listProjects(), [])
    }

    func testManifestSelectionReviewsBeforeExplicitStoppedImport() throws {
        let fixture = try makeFixture(name: "ManifestRepositoryPicker")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifestDirectory = fixture.projectDirectory
            .appendingPathComponent(".localwrap", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try Data(#"{"localwrap":1,"name":"Fixture Stack","projects":[{"id":"app","path":".","command":"npm start","port":3000}]}"#.utf8)
            .write(to: manifestDirectory.appendingPathComponent("workspace.json"))
        let model = AppModel(
            store: fixture.store,
            directoryPicker: DirectoryPickerService(
                chooseRepository: { fixture.projectDirectory }
            )
        )

        model.chooseRepository()

        guard case .workspace(let firstReview) = model.repositoryOpenProposal else {
            return XCTFail("Expected workspace manifest review.")
        }
        XCTAssertTrue(firstReview.canImport)
        XCTAssertEqual(try fixture.store.listProjects(), [])

        model.dismissRepositoryProposal()
        XCTAssertNil(model.repositoryOpenProposal)
        XCTAssertEqual(try fixture.store.listProjects(), [])

        model.reviewRepository(at: fixture.projectDirectory)
        guard case .workspace(let review) = model.repositoryOpenProposal else {
            return XCTFail("Expected workspace manifest review.")
        }
        XCTAssertTrue(model.importWorkspacePack(review))
        XCTAssertNil(model.repositoryOpenProposal)
        XCTAssertEqual(model.projects.map(\.name), ["app"])
        XCTAssertEqual(try fixture.store.listProjects().map(\.name), ["app"])
        XCTAssertEqual(model.runtime(for: model.projects[0].id).status, .stopped)
    }

    func testManifestImportDoesNotMutateRunningProjectConfiguration() async throws {
        let fixture = try makeFixture(name: "RunningManifestImport")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let packURL = fixture.projectDirectory.appendingPathComponent("localwrap.json")
        try Data(#"{"localwrap":1,"projects":[{"id":"app","path":".","command":"npm start","port":3000}]}"#.utf8)
            .write(to: packURL)
        let packs = WorkspacePackService()
        let firstReview = try packs.inspect(rootURL: fixture.projectDirectory)
        let first = try packs.importReviewed(firstReview, into: fixture.store)
        let project = try XCTUnwrap(first.projects.first)
        try Data(#"{"localwrap":1,"projects":[{"id":"app","path":".","command":"npm run dev","port":3000}]}"#.utf8)
            .write(to: packURL)
        let updateReview = try packs.inspect(
            rootURL: fixture.projectDirectory,
            projects: first.projects,
            workspace: first.workspace
        )
        let recorder = DesktopRecorder()
        let model = AppModel(
            projects: first.projects,
            workspace: first.workspace,
            initialRuntimes: [project.id: RuntimeSnapshot(status: .ready)],
            store: fixture.store,
            desktopActions: DesktopActionService(
                revealFolder: { recorder.recordFolder($0) },
                copyText: { recorder.recordText($0) },
                openURL: { _ in }
            ),
            workspacePacks: packs
        )

        model.revealWorkspaceManifest(updateReview)
        model.copyWorkspaceManifestPath(updateReview)
        model.reviewWorkspaceManifestAgain(updateReview)
        XCTAssertEqual(recorder.folder?.path, packURL.path)
        XCTAssertEqual(recorder.text, packURL.path)
        guard case .workspace = model.repositoryOpenProposal else {
            return XCTFail("Review Again should refresh the workspace proposal.")
        }
        XCTAssertEqual(
            model.workspacePackImportBlockReason(for: updateReview),
            "Stop these projects before importing configuration changes: app."
        )
        XCTAssertEqual(model.workspacePackActiveUpdateProjectIDs(for: updateReview), [project.id])
        XCTAssertFalse(model.importWorkspacePack(updateReview))
        XCTAssertTrue(model.errorMessage?.contains("Stop these projects") == true)
        XCTAssertEqual(try fixture.store.project(id: project.id)?.command, "npm start")

        await model.stopProjectsBlockingWorkspacePackImport(updateReview)
        XCTAssertNil(model.workspacePackImportBlockReason(for: updateReview))
    }

    func testLiveModelLoadsPersistedCounts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let paths = ProjectStorePaths(
            directory: root,
            store: root.appendingPathComponent("store.json"),
            backup: root.appendingPathComponent("store.json.bak"),
            electronStore: root.appendingPathComponent("electron.json")
        )
        let store = ProjectStore(
            paths: paths,
            now: { "2026-07-10T05:00:00.000Z" },
            makeID: { "project" }
        )
        let project = try store.createProject(
            ProjectDraft(
                name: "Demo",
                cwd: projectDirectory.path,
                command: "npm start",
                port: 3_000,
                url: "http://localhost:3000"
            )
        )
        _ = try store.writeWorkspace(
            WorkspaceState(
                lastRunningProjectIds: [],
                savedWorkspaces: [
                    WorkspaceProfile(
                        id: "workspace",
                        name: "Stack",
                        projectIds: [project.id],
                        createdAt: "2026-07-10T05:00:00.000Z",
                        updatedAt: "2026-07-10T05:00:00.000Z",
                        lastStartedAt: nil,
                        source: nil
                    ),
                ],
                updatedAt: "2026-07-10T05:00:00.000Z"
            )
        )

        let model = AppModel.live(store: store)

        XCTAssertEqual(model.projectCount, 1)
        XCTAssertEqual(model.workspaceCount, 1)
        XCTAssertEqual(model.persistenceStatus, .ready(.existingNativeStore))
    }

    func testModelCreatesAndUpdatesPersistedProjectDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelEdit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let paths = ProjectStorePaths(
            directory: root,
            store: root.appendingPathComponent("store.json"),
            backup: root.appendingPathComponent("store.json.bak"),
            electronStore: root.appendingPathComponent("electron.json")
        )
        let store = ProjectStore(
            paths: paths,
            now: { "2026-07-10T12:00:00Z" },
            makeID: { "project" }
        )
        let model = AppModel.live(store: store)
        let original = ProjectDraft(
            name: "Demo",
            cwd: projectDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000"
        )

        let created = await model.saveProject(
            draft: original,
            existingID: nil,
            startAfterSave: false
        )
        var update = original
        update.name = "Renamed"
        _ = await model.saveProject(
            draft: update,
            existingID: created?.id,
            startAfterSave: false
        )

        XCTAssertEqual(model.projectCount, 1)
        XCTAssertEqual(model.projects.first?.name, "Renamed")
        XCTAssertEqual(try store.listProjects().first?.id, "project")
    }

    func testSaveAndStartReturnsPersistedProjectWhenLaunchFails() async throws {
        let fixture = try makeFixture(name: "SaveThenStart")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let doctor = ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: { _ in true })
        )
        let runtime = RuntimeService(
            environmentResolver: EnvironmentResolver(
                environment: { ["PATH": "/missing"] },
                isExecutable: { _ in false }
            ),
            doctor: doctor,
            isDirectory: { _ in true }
        )
        let model = AppModel.live(
            store: fixture.store,
            runtimeService: runtime,
            doctorService: doctor
        )
        let draft = ProjectDraft(
            name: "Demo",
            cwd: fixture.projectDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000"
        )

        let result = await model.saveProject(
            draft: draft,
            existingID: nil,
            startAfterSave: true
        )

        XCTAssertEqual(result?.id, "project")
        XCTAssertEqual(model.projectCount, 1)
        XCTAssertEqual(try fixture.store.listProjects().map(\.id), ["project"])
        XCTAssertNotNil(model.errorMessage)
    }

    func testDraftAndSavedDoctorFixesRespectPersistenceAndDirtyGuards() async throws {
        let fixture = try makeFixture(name: "DoctorActions")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let doctor = ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: { $0 == 3_001 }),
            now: { "2026-07-10T12:00:00Z" }
        )
        let model = AppModel.live(store: fixture.store, doctorService: doctor)
        let original = ProjectDraft(
            name: "Demo",
            cwd: fixture.projectDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000"
        )

        let inMemory = await model.performDoctorAction(
            .findFreePort,
            draft: original,
            existingID: nil,
            isDirty: true,
            diagnosis: doctor.diagnose(original)
        )
        XCTAssertEqual(inMemory?.port, 3_001)
        XCTAssertEqual(try fixture.store.listProjects(), [])

        let saved = try fixture.store.createProject(original)
        let persisted = await model.performDoctorAction(
            .findFreePort,
            draft: ProjectDraft(project: saved),
            existingID: saved.id,
            isDirty: false,
            diagnosis: doctor.diagnose(ProjectDraft(project: saved))
        )
        XCTAssertEqual(persisted?.port, 3_001)
        XCTAssertEqual(try fixture.store.project(id: saved.id)?.url, "http://localhost:3001")

        let rejected = await model.performDoctorAction(
            .syncURL,
            draft: persisted ?? original,
            existingID: saved.id,
            isDirty: true,
            diagnosis: doctor.diagnose(persisted ?? original)
        )
        XCTAssertNil(rejected)
        XCTAssertEqual(model.errorMessage, DoctorError.dirtyProject.localizedDescription)
    }

    func testFinderAndPreviewedDoctorReportUseInjectedDesktopService() async throws {
        let fixture = try makeFixture(name: "DesktopActions")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = DesktopRecorder()
        let desktop = DesktopActionService(
            revealFolder: { recorder.recordFolder($0) },
            copyText: { recorder.recordText($0) },
            openURL: { _ in }
        )
        let model = AppModel.live(store: fixture.store, desktopActions: desktop)
        let draft = ProjectDraft(
            name: "Demo",
            cwd: fixture.projectDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000"
        )
        let diagnosis = model.diagnose(draft)

        _ = await model.performDoctorAction(
            .revealFolder,
            draft: draft,
            existingID: nil,
            isDirty: false,
            diagnosis: diagnosis
        )
        let directCopy = await model.performDoctorAction(
            .copyReport,
            draft: draft,
            existingID: nil,
            isDirty: false,
            diagnosis: diagnosis
        )

        XCTAssertEqual(recorder.folder?.path, fixture.projectDirectory.path)
        XCTAssertNil(directCopy)
        XCTAssertNil(recorder.text)
        XCTAssertEqual(
            model.errorMessage,
            DoctorError.reportPreviewRequired.localizedDescription
        )

        let report = model.buildDoctorReport(
            draft: draft,
            existingID: nil,
            diagnosis: diagnosis
        )
        XCTAssertEqual(report.previewText, report.copyText)
        XCTAssertNil(recorder.text)

        model.copyDoctorReport(report)

        XCTAssertEqual(recorder.text, report.previewText)
        XCTAssertTrue(report.previewText.contains("LocalWrap Redacted Doctor Report"))
    }

    func testActiveProjectRejectsProtectedConfigurationMutation() async throws {
        let fixture = try makeFixture(name: "ActiveGuard")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launcher = AppModelFakeLauncher()
        let doctor = ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: { _ in true })
        )
        let runtime = RuntimeService(
            environmentResolver: EnvironmentResolver(
                environment: { ["PATH": "/tools"] },
                isExecutable: { $0 == "/tools/npm" }
            ),
            launcher: launcher,
            readiness: AppModelReadiness(),
            doctor: doctor,
            isDirectory: { _ in true }
        )
        let model = AppModel.live(
            store: fixture.store,
            runtimeService: runtime,
            doctorService: doctor
        )
        let original = ProjectDraft(
            name: "Demo",
            cwd: fixture.projectDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000"
        )
        let saved = await model.saveProject(draft: original, existingID: nil, startAfterSave: false)
        let project = try XCTUnwrap(saved)
        try await model.startProject(id: project.id)
        var changed = original
        changed.port = 4_000

        let result = await model.saveProject(
            draft: changed,
            existingID: project.id,
            startAfterSave: false
        )

        XCTAssertNil(result)
        XCTAssertEqual(model.errorMessage, DoctorError.activeProject.localizedDescription)
        XCTAssertEqual(try fixture.store.project(id: project.id)?.port, 3_000)
        await model.stopProject(id: project.id)
    }

    func testStopAllCapturesLastRunningProjectsForReloadedModel() async throws {
        let fixture = try makeFixture(name: "WorkspaceResume")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launcher = AppModelFakeLauncher()
        let doctor = ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: { _ in true })
        )
        let runtime = RuntimeService(
            environmentResolver: EnvironmentResolver(
                environment: { ["PATH": "/tools"] },
                isExecutable: { $0 == "/tools/npm" }
            ),
            launcher: launcher,
            readiness: AppModelReadiness(),
            doctor: doctor,
            isDirectory: { _ in true }
        )
        let project = try fixture.store.createProject(ProjectDraft(
            name: "Demo",
            cwd: fixture.projectDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000"
        ))
        let model = AppModel.live(store: fixture.store, runtimeService: runtime, doctorService: doctor)
        try await model.startProject(id: project.id)

        await model.stopAllProjects()
        let reloaded = AppModel.live(store: fixture.store)

        XCTAssertEqual(reloaded.workspace.lastRunningProjectIds, [project.id])
    }

    func testManualReleaseCheckPublishesNoticeAndOpensOnlyTrustedReleasePage() async throws {
        let recorder = DesktopRecorder()
        let releaseURL = URL(
            string: "https://github.com/tcballard/LocalWrap/releases/tag/v3.4.0"
        )!
        let checker = ReleaseCheckService { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let data = Data("""
            {
              "tag_name": "v3.4.0",
              "html_url": "\(releaseURL.absoluteString)",
              "draft": false,
              "prerelease": false
            }
            """.utf8)
            return (data, response)
        }
        let model = AppModel(
            desktopActions: DesktopActionService(
                revealFolder: { _ in },
                copyText: { _ in },
                openURL: recorder.recordURL
            ),
            releaseChecker: checker,
            currentVersion: { "3.3.0" }
        )

        await model.checkForUpdates()

        XCTAssertEqual(
            model.releaseNotice,
            ReleaseNotice(
                title: "LocalWrap 3.4.0 is available",
                message: "A newer stable release is available on GitHub.",
                releaseURL: releaseURL
            )
        )
        model.openReleasePage(releaseURL)
        model.openReleasePage(URL(string: "https://example.com/releases/tag/v3.4.0")!)
        XCTAssertEqual(recorder.url, releaseURL)
    }

    func testOverlappingManualReleaseChecksShareOneInFlightRequest() async throws {
        let gate = ReleaseGate()
        let checker = ReleaseCheckService { request in
            await gate.wait()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data("""
            {
              "tag_name": "v3.3.0",
              "html_url": "https://github.com/tcballard/LocalWrap/releases/tag/v3.3.0",
              "draft": false,
              "prerelease": false
            }
            """.utf8), response)
        }
        let model = AppModel(releaseChecker: checker, currentVersion: { "3.3.0" })

        let first = Task { await model.checkForUpdates() }
        for _ in 0..<100 {
            if await gate.callCount > 0 { break }
            await Task.yield()
        }
        XCTAssertTrue(model.isCheckingForUpdates)
        await model.checkForUpdates()
        let callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)

        await gate.resume()
        await first.value
        XCTAssertFalse(model.isCheckingForUpdates)
        XCTAssertEqual(model.releaseNotice?.title, "LocalWrapMac is up to date")
    }

    private func makeFixture(name: String) throws -> (
        root: URL,
        projectDirectory: URL,
        store: ProjectStore
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try Data(#"{"scripts":{"start":"node server.js"}}"#.utf8)
            .write(to: projectDirectory.appendingPathComponent("package.json"))
        let paths = ProjectStorePaths(
            directory: root,
            store: root.appendingPathComponent("store.json"),
            backup: root.appendingPathComponent("store.json.bak"),
            electronStore: root.appendingPathComponent("electron.json")
        )
        return (
            root,
            projectDirectory,
            ProjectStore(
                paths: paths,
                now: { "2026-07-10T12:00:00Z" },
                makeID: { "project" }
            )
        )
    }
}

private final class AppModelIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.withLock { values.removeFirst() }
    }
}

private enum AppModelManagedRuntimeFixtures {
    static func record(for project: Project) -> RuntimeLedgerRecord {
        RuntimeLedgerRecord(
            runID: "recovered-run",
            projectID: project.id,
            pid: 7_001,
            processGroupID: 7_001,
            sessionID: 7_001,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567),
            commandFingerprint: ProcessCommandFingerprint.makeLaunchContract(
                executablePath: "/tools/npm",
                arguments: ["start"],
                workingDirectory: URL(fileURLWithPath: project.cwd, isDirectory: true),
                port: project.port,
                readinessURL: URL(string: project.url)!
            ),
            observedProcessFingerprint: String(repeating: "b", count: 64),
            port: project.port,
            startedAt: "2026-07-19T00:00:00Z",
            logFilename: "run-recovered.log"
        )
    }
}

private final class AppModelManagedLedger: RuntimeLedgerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [RuntimeLedgerRecord]

    init(records: [RuntimeLedgerRecord]) {
        self.records = records
    }

    func load() throws -> RuntimeLedgerDocument {
        lock.withLock { RuntimeLedgerDocument(records: records) }
    }

    func save(_ document: RuntimeLedgerDocument) throws -> RuntimeLedgerDocument {
        lock.withLock { records = document.records }
        return document
    }

    func upsert(_ record: RuntimeLedgerRecord) throws -> RuntimeLedgerDocument {
        lock.withLock {
            records.removeAll { $0.runID == record.runID }
            records.append(record)
            return RuntimeLedgerDocument(records: records)
        }
    }

    func remove(runID: String) throws -> RuntimeLedgerDocument {
        lock.withLock {
            records.removeAll { $0.runID == runID }
            return RuntimeLedgerDocument(records: records)
        }
    }

    func logURL(for filename: String) throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    func removeLog(filename: String) throws {}
}

private final class AppModelGatedInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false
    private var gated = false

    var reconciliationStarted: Bool { lock.withLock { started } }

    func finishReconciliation() {
        gate.signal()
    }

    func capture(
        pid: Int32,
        commandFingerprint: String
    ) throws -> ProcessOwnershipObservation {
        ProcessOwnershipObservation(
            pid: pid,
            processGroupID: pid,
            sessionID: pid,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567),
            commandFingerprint: commandFingerprint,
            observedProcessFingerprint: String(repeating: "b", count: 64)
        )
    }

    func inspect(_ expectation: ProcessOwnershipExpectation) -> ProcessOwnershipAssessment {
        let shouldWait = lock.withLock {
            started = true
            guard !gated else { return false }
            gated = true
            return true
        }
        if shouldWait { gate.wait() }
        return .verified(VerifiedProcessOwnership(
            pid: expectation.pid,
            processGroupID: expectation.processGroupID,
            sessionID: expectation.sessionID,
            effectiveUserID: expectation.effectiveUserID,
            kernelStartTime: expectation.kernelStartTime,
            observedProcessFingerprint: expectation.observedProcessFingerprint,
            processGroupMembers: [expectation.pid]
        ))
    }
}

private final class AppModelGatedExitedInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false
    private var gated = false

    var reconciliationStarted: Bool { lock.withLock { started } }

    func finishReconciliation() {
        gate.signal()
    }

    func capture(
        pid: Int32,
        commandFingerprint: String
    ) throws -> ProcessOwnershipObservation {
        throw CocoaError(.fileReadNoSuchFile)
    }

    func inspect(_ expectation: ProcessOwnershipExpectation) -> ProcessOwnershipAssessment {
        let shouldWait = lock.withLock {
            started = true
            guard !gated else { return false }
            gated = true
            return true
        }
        if shouldWait { gate.wait() }
        return .exited
    }
}

private final class AppModelManagedLauncher: RecoverableProjectProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var prepared = 0
    private var monitored = 0

    var prepareCount: Int { lock.withLock { prepared } }
    var monitorCount: Int { lock.withLock { monitored } }

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        try prepareLaunch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            logURL: FileManager.default.temporaryDirectory.appendingPathComponent("legacy.log"),
            onOutput: onOutput,
            onExit: onExit
        )
    }

    func prepareLaunch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        logURL: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        lock.withLock { prepared += 1 }
        return AppModelManagedProcess(pid: 8_001, logURL: logURL)
    }

    func monitorExisting(
        pid: Int32,
        processGroupID: Int32,
        logURL: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        lock.withLock { monitored += 1 }
        return AppModelManagedProcess(pid: pid, processGroupID: processGroupID, logURL: logURL)
    }
}

private final class AppModelManagedProcess: ManagedProjectProcess, @unchecked Sendable {
    let pid: Int32
    let processGroupID: Int32
    let logURL: URL?
    var isRunning: Bool { true }

    init(pid: Int32, processGroupID: Int32? = nil, logURL: URL?) {
        self.pid = pid
        self.processGroupID = processGroupID ?? pid
        self.logURL = logURL
    }

    func resume() throws {}
    func signalProcessGroup(_ signal: Int32) throws {}
}

private struct AppModelImmediateReadiness: ReadinessProbing {
    func waitUntilReady(url: URL, timeout: Duration, interval: Duration) async -> Bool {
        true
    }
}

private final class DesktopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFolder: URL?
    private var storedText: String?
    private var storedURL: URL?

    var folder: URL? { lock.withLock { storedFolder } }
    var text: String? { lock.withLock { storedText } }
    var url: URL? { lock.withLock { storedURL } }
    func recordFolder(_ url: URL) { lock.withLock { storedFolder = url } }
    func recordText(_ text: String) { lock.withLock { storedText = text } }
    func recordURL(_ url: URL) { lock.withLock { storedURL = url } }
}

private actor ReleaseGate {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct AppModelReadiness: ReadinessProbing {
    func waitUntilReady(url: URL, timeout: Duration, interval: Duration) async -> Bool {
        try? await Task.sleep(for: .seconds(10))
        return false
    }
}

private final class AppModelFakeLauncher: ProjectProcessLaunching, @unchecked Sendable {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        AppModelFakeProcess(onExit: onExit)
    }
}

private final class AppModelFakeProcess: ManagedProjectProcess, @unchecked Sendable {
    let pid: Int32 = 77
    private let lock = NSLock()
    private var running = true
    private let onExit: @Sendable (Int32) -> Void

    var isRunning: Bool { lock.withLock { running } }

    init(onExit: @escaping @Sendable (Int32) -> Void) {
        self.onExit = onExit
    }

    func signalProcessGroup(_ signal: Int32) {
        let shouldExit = lock.withLock {
            guard running else { return false }
            running = false
            return true
        }
        if shouldExit { onExit(128 + signal) }
    }
}
