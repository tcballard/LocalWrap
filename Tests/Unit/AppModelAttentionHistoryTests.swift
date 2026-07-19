import Foundation
import XCTest
@testable import LocalWrapMac

@MainActor
final class AppModelAttentionHistoryTests: XCTestCase {
    func testWorkspaceOperationFailureSurvivesTargetSwitchAndReloadUntilRuntimeResolves() async throws {
        let fixture = try Fixture(name: "RetainedWorkspaceFailure")
        defer { fixture.remove() }
        let doctor = ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: { _ in true }),
            now: { "2026-07-19T12:00:00Z" }
        )
        let runtime = fixture.runtime(doctor: doctor, readiness: ReadyProbe())
        let workspaceDoctor = WorkspaceDoctorService(
            projectDoctor: doctor,
            portSuggester: PortSuggestionService(isAvailable: { _ in true })
        )
        let project = try fixture.makeProject()
        let model = AppModel.live(
            store: fixture.store,
            runtimeService: runtime,
            doctorService: doctor,
            workspaceOrchestration: WorkspaceOrchestrationService(
                runtime: FailingWorkspaceRuntime(),
                doctor: workspaceDoctor
            ),
            attentionService: AttentionService(now: { "2026-07-19T12:00:00Z" })
        )
        try await waitUntil { model.runtimeControlsAvailable }

        await model.startWorkspace(target: .allProjects, readyOnly: false)
        try await waitUntil {
            model.attentionSnapshot.issues.contains { $0.sources.contains(.workspaceOperation) }
        }

        let profile = try XCTUnwrap(model.saveWorkspaceProfile(
            id: nil,
            name: "Saved Stack",
            projectIDs: [project.id]
        ))
        model.diagnoseWorkspace(target: .profile(profile.id))
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(model.attentionSnapshot.issues.contains {
            $0.sources.contains(.workspaceOperation)
        })

        try await model.startProject(id: project.id)
        try await waitUntil { model.runtime(for: project.id).status == .ready }
        try await waitUntil {
            !model.attentionSnapshot.issues.contains { $0.sources.contains(.workspaceOperation) }
        }
    }

    func testRunHistoryCaptureBuildsExactRedactedReportAndClearsPerProject() async throws {
        let fixture = try Fixture(name: "RunHistoryCapture")
        defer { fixture.remove() }
        let doctor = ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: { _ in true }),
            now: { "2026-07-19T12:00:00Z" }
        )
        let runtime = fixture.runtime(doctor: doctor, readiness: ReadyProbe())
        let historyPaths = RunHistoryPaths(
            directory: fixture.root.appendingPathComponent("history", isDirectory: true),
            history: fixture.root.appendingPathComponent("history/run-history.json")
        )
        let coordinator = RunHistoryCoordinator(
            service: RunHistoryService(store: RunHistoryStore(paths: historyPaths))
        )
        let project = try fixture.makeProject(
            name: "SECRET_PROJECT_NAME",
            command: "npm start --token=SECRET_COMMAND_TOKEN"
        )
        let model = AppModel.live(
            store: fixture.store,
            runtimeService: runtime,
            doctorService: doctor,
            runHistoryCoordinator: coordinator,
            currentVersion: { "0.1.1" }
        )
        try await waitUntil { model.runtimeControlsAvailable }

        try await model.startProject(id: project.id)
        try await waitUntil { model.runtime(for: project.id).status == .ready }
        await model.stopProject(id: project.id)
        try await waitUntil { !model.runHistoryDocument.records.isEmpty }

        let builtReport = await model.buildSupportReport()
        let report = try XCTUnwrap(builtReport)
        XCTAssertEqual(report.previewText, report.copyText)
        XCTAssertEqual(report.copyText, report.exportText)
        for sentinel in [
            "SECRET_PROJECT_NAME",
            "SECRET_COMMAND_TOKEN",
            fixture.projectDirectory.path,
            project.url,
        ] {
            XCTAssertFalse(report.previewText.contains(sentinel), "Support report leaked \(sentinel)")
        }

        await model.clearRunHistory(projectID: project.id)
        XCTAssertTrue(model.runHistoryDocument.records.isEmpty)
    }

    private func waitUntil(
        attempts: Int = 300,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for AppModel state")
    }
}

private final class Fixture {
    let root: URL
    let projectDirectory: URL
    let store: ProjectStore

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{"scripts":{"start":"node server.js"}}"#.utf8)
            .write(to: projectDirectory.appendingPathComponent("package.json"))
        store = ProjectStore(
            paths: ProjectStorePaths(
                directory: root,
                store: root.appendingPathComponent("store.json"),
                backup: root.appendingPathComponent("store.json.bak"),
                electronStore: root.appendingPathComponent("electron.json")
            ),
            now: { "2026-07-19T12:00:00Z" },
            makeID: { "history-project" }
        )
    }

    func makeProject(
        name: String = "Web",
        command: String = "npm start"
    ) throws -> Project {
        try store.createProject(ProjectDraft(
            name: name,
            cwd: projectDirectory.path,
            command: command,
            port: 4_321,
            url: "http://localhost:4321"
        ))
    }

    func runtime(
        doctor: ProjectDoctorService,
        readiness: any ReadinessProbing
    ) -> RuntimeService {
        RuntimeService(
            environmentResolver: EnvironmentResolver(
                environment: { ["PATH": "/tools"] },
                isExecutable: { $0 == "/tools/npm" }
            ),
            launcher: TestLauncher(),
            readiness: readiness,
            doctor: doctor,
            now: { "2026-07-19T12:00:00Z" },
            isDirectory: { _ in true }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ReadyProbe: ReadinessProbing {
    func waitUntilReady(url: URL, timeout: Duration, interval: Duration) async -> Bool { true }
}

private actor FailingWorkspaceRuntime: WorkspaceRuntimeControlling {
    func snapshot(for projectID: String) -> RuntimeSnapshot { RuntimeSnapshot() }

    func start(_ project: Project) throws -> RuntimeSnapshot {
        RuntimeSnapshot(
            status: .starting,
            runID: "workspace-failure-run",
            startedAt: "2026-07-19T12:00:00Z"
        )
    }

    func waitForReady(
        projectID: String,
        timeout: Duration,
        pollInterval: Duration
    ) -> RuntimeSnapshot {
        RuntimeSnapshot(
            status: .failed,
            runID: "workspace-failure-run",
            terminalReason: .readinessTimeout,
            startedAt: "2026-07-19T12:00:00Z",
            stoppedAt: "2026-07-19T12:00:01Z"
        )
    }

    func stopAll() {}
}

private final class TestLauncher: ProjectProcessLaunching, @unchecked Sendable {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        TestProcess(onExit: onExit)
    }
}

private final class TestProcess: ManagedProjectProcess, @unchecked Sendable {
    let pid: Int32 = 91
    private let lock = NSLock()
    private let onExit: @Sendable (Int32) -> Void
    private var running = true

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
        if shouldExit { onExit(0) }
    }
}
