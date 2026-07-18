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

    func testManifestImportDoesNotMutateRunningProjectConfiguration() throws {
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
        let model = AppModel(
            projects: first.projects,
            workspace: first.workspace,
            initialRuntimes: [project.id: RuntimeSnapshot(status: .ready)],
            store: fixture.store,
            workspacePacks: packs
        )

        XCTAssertFalse(model.importWorkspacePack(updateReview))
        XCTAssertTrue(model.errorMessage?.contains("Stop these projects") == true)
        XCTAssertEqual(try fixture.store.project(id: project.id)?.command, "npm start")
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

    func testFinderAndPasteboardDoctorActionsUseInjectedDesktopService() async throws {
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
        _ = await model.performDoctorAction(
            .copyReport,
            draft: draft,
            existingID: nil,
            isDirty: false,
            diagnosis: diagnosis
        )

        XCTAssertEqual(recorder.folder?.path, fixture.projectDirectory.path)
        XCTAssertTrue(recorder.text?.contains("LocalWrap Doctor Report") == true)
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
