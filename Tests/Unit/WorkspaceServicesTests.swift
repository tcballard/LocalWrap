import Darwin
import Foundation
import XCTest
@testable import LocalWrapMac

final class WorkspaceServicesTests: XCTestCase {
    private var root: URL!
    private var apiDirectory: URL!
    private var webDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceServices-\(UUID().uuidString)", isDirectory: true)
        apiDirectory = root.appendingPathComponent("api", isDirectory: true)
        webDirectory = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: apiDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: webDirectory, withIntermediateDirectories: true)
        let package = Data(#"{"scripts":{"dev":"node server.js"}}"#.utf8)
        try package.write(to: apiDirectory.appendingPathComponent("package.json"))
        try package.write(to: webDirectory.appendingPathComponent("package.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHealthChecksAndStableGraphOrderingShareLocalRules() throws {
        let api = project("api", "API", apiDirectory, 4_000)
        let web = project("web", "Web", webDirectory, 5_173, dependsOn: ["api"])
        let graph = WorkspaceGraph()

        XCTAssertEqual(graph.stableTopologicalOrder([web, api]).map(\.id), ["api", "web"])
        XCTAssertTrue(graph.cycleProjectIDs([web, api]).isEmpty)
        XCTAssertEqual(
            HealthCheckResolver().resolve(
                projectURL: web.url,
                healthCheck: HealthCheck(path: "/ready")
            ).url?.absoluteString,
            "http://localhost:5173/ready"
        )
        XCTAssertFalse(HealthCheckResolver().resolve(
            projectURL: web.url,
            healthCheck: HealthCheck(path: "ready")
        ).isValid)
    }

    func testGraphFindsCyclesWithoutDisturbingIndependentBranch() {
        let api = project("api", "API", apiDirectory, 4_000, dependsOn: ["web"])
        let web = project("web", "Web", webDirectory, 5_173, dependsOn: ["api"])
        let docs = project("docs", "Docs", webDirectory, 6_000)
        let graph = WorkspaceGraph()

        XCTAssertEqual(graph.cycleProjectIDs([api, docs, web]), Set(["api", "web"]))
        XCTAssertEqual(graph.stableTopologicalOrder([web, docs, api]).map(\.id), ["api", "web", "docs"])
    }

    func testWorkspaceDoctorCoversEightChecksWarningsAndTargetFallback() throws {
        try Data("API_TOKEN=\nDATABASE_URL=\n".utf8)
            .write(to: apiDirectory.appendingPathComponent(".env.example"))
        try Data("DATABASE_URL=not-exposed\n".utf8)
            .write(to: apiDirectory.appendingPathComponent(".env"))
        let api = project("api", "API", apiDirectory, 4_000)
        let web = project("web", "Web", webDirectory, 5_173, dependsOn: ["api"])
        let doctor = makeDoctor()
        let workspace = WorkspaceState(
            lastRunningProjectIds: ["web", "api"],
            savedWorkspaces: [],
            updatedAt: nil
        )

        let diagnosis = try doctor.diagnose(projects: [web, api], workspace: workspace)

        XCTAssertEqual(diagnosis.target.kind, .lastRunning)
        XCTAssertEqual(diagnosis.checks.map(\.id), WorkspaceCheckID.allCases)
        XCTAssertEqual(diagnosis.status, .attention)
        XCTAssertEqual(diagnosis.startableProjectIDs, ["web", "api"])
        XCTAssertEqual(diagnosis.projects.first { $0.id == "api" }?.issues.first {
            $0.code == "env-vars-missing"
        }?.message, "Missing env value(s): API_TOKEN.")
        XCTAssertEqual(doctor.parseEnvironmentKeys("FOO=secret\nexport BAR=other\n# NOPE=x"), ["FOO", "BAR"])
    }

    func testWorkspaceDoctorBlocksDuplicatePortsCyclesAndDownstreamProjects() throws {
        var api = project("api", "API", apiDirectory, 4_000)
        var web = project("web", "Web", webDirectory, 4_000, dependsOn: ["api"])
        api.dependsOn = ["web"]
        web.healthCheck = HealthCheck(path: "invalid")
        let diagnosis = try makeDoctor().diagnose(
            projects: [api, web],
            workspace: .empty,
            target: .allProjects
        )

        XCTAssertEqual(diagnosis.status, .blocked)
        XCTAssertEqual(Set(diagnosis.blockedProjectIDs), Set(["api", "web"]))
        XCTAssertEqual(diagnosis.checks.first { $0.id == .ports }?.status, .fail)
        XCTAssertEqual(diagnosis.checks.first { $0.id == .startup }?.status, .fail)
    }

    func testWorkspaceDoctorReportsMissingAndOutsideDependencies() throws {
        let api = project("api", "API", apiDirectory, 4_000)
        let web = project("web", "Web", webDirectory, 5_173, dependsOn: ["api", "missing"])
        let profile = WorkspaceProfile(
            id: "frontend",
            name: "Frontend",
            projectIds: ["web"],
            createdAt: nil,
            updatedAt: nil,
            lastStartedAt: nil,
            source: nil
        )
        let diagnosis = try makeDoctor().diagnose(
            projects: [api, web],
            workspace: WorkspaceState(
                lastRunningProjectIds: [],
                savedWorkspaces: [profile],
                updatedAt: nil
            ),
            target: .profile("frontend")
        )

        XCTAssertEqual(diagnosis.blockedProjectIDs, ["web"])
        XCTAssertTrue(diagnosis.projects[0].issues.contains { $0.code == "dependency-missing" })
        XCTAssertTrue(diagnosis.projects[0].issues.contains { $0.code == "dependency-outside-workspace" })
    }

    func testOrchestrationWaitsForReadyAndContinuesIndependentBranch() async throws {
        let api = project("api", "API", apiDirectory, 4_000)
        let web = project("web", "Web", webDirectory, 5_173, dependsOn: ["api"])
        let docs = project("docs", "Docs", webDirectory, 6_000)
        let runtime = WorkspaceFakeRuntime(finalStatuses: [
            "api": .failed,
            "docs": .ready,
        ])
        let service = WorkspaceOrchestrationService(runtime: runtime, doctor: makeDoctor())

        let (_, summary) = try await service.start(
            projects: [web, docs, api],
            workspace: .empty,
            target: .allProjects,
            startReadyOnly: false,
            waitTimeout: .seconds(1)
        )

        let startedIDs = await runtime.startedIDs()
        XCTAssertEqual(startedIDs, ["api", "docs"])
        XCTAssertEqual(summary.results.map(\.projectID), ["api", "web", "docs"])
        XCTAssertEqual(summary.results.first { $0.projectID == "api" }?.status, .failed)
        XCTAssertEqual(summary.results.first { $0.projectID == "web" }?.blockedByProjectIDs, ["api"])
        XCTAssertEqual(summary.results.first { $0.projectID == "docs" }?.status, .started)
    }

    func testOwnActivePortDoesNotProduceBusyWarning() throws {
        let api = project("api", "API", apiDirectory, 4_000)
        let doctor = makeDoctor(portAvailable: false)
        let diagnosis = try doctor.diagnose(
            projects: [api],
            workspace: .empty,
            target: .allProjects,
            runtimes: ["api": RuntimeSnapshot(status: .ready)]
        )
        XCTAssertFalse(diagnosis.projects[0].issues.contains { $0.code == "port-busy" })
    }

    func testRealDependencyStackStartsInOrderAndCleansBothProcessGroups() async throws {
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples/sample-project", isDirectory: true)
        let ports = PortSuggestionService()
        let apiPort = try ports.suggest(preferred: 4_322)
        let webPort = try ports.suggest(preferred: apiPort + 1)
        let api = project("real-api", "API", sample, apiPort)
        let web = project("real-web", "Web", sample, webPort, dependsOn: [api.id])
        let runtime = RuntimeService()
        let service = WorkspaceOrchestrationService(runtime: runtime)

        do {
            let (_, summary) = try await service.start(
                projects: [web, api],
                workspace: .empty,
                target: .allProjects,
                startReadyOnly: false,
                waitTimeout: .seconds(10)
            )
            XCTAssertEqual(summary.results.map(\.projectID), [api.id, web.id])
            XCTAssertEqual(summary.started, 2)
            let apiSnapshot = await runtime.snapshot(for: api.id)
            let webSnapshot = await runtime.snapshot(for: web.id)
            let apiPID = try XCTUnwrap(apiSnapshot.pid)
            let webPID = try XCTUnwrap(webSnapshot.pid)

            await service.stopAll()

            let apiExited = await processGroupExited(apiPID)
            let webExited = await processGroupExited(webPID)
            XCTAssertTrue(apiExited, "API process group survived Stop All")
            XCTAssertTrue(webExited, "Web process group survived Stop All")
        } catch {
            await service.stopAll()
            throw error
        }
    }

    private func makeDoctor(portAvailable: Bool = true) -> WorkspaceDoctorService {
        let ports = PortSuggestionService(isAvailable: { _ in portAvailable })
        return WorkspaceDoctorService(
            projectDoctor: ProjectDoctorService(portSuggester: ports),
            portSuggester: ports,
            now: { "2026-07-10T20:00:00Z" }
        )
    }

    private func project(
        _ id: String,
        _ name: String,
        _ directory: URL,
        _ port: Int,
        dependsOn: [String]? = nil
    ) -> Project {
        Project(
            id: id,
            name: name,
            cwd: directory.path,
            command: "npm run dev",
            port: port,
            url: "http://localhost:\(port)",
            createdAt: "2026-07-10T20:00:00Z",
            updatedAt: "2026-07-10T20:00:00Z",
            dependsOn: dependsOn
        )
    }

    private func processGroupExited(_ pid: Int32) async -> Bool {
        for _ in 0..<30 {
            errno = 0
            if Darwin.kill(-pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

private actor WorkspaceFakeRuntime: WorkspaceRuntimeControlling {
    private var states: [String: RuntimeSnapshot] = [:]
    private let finalStatuses: [String: RuntimeStatus]
    private var starts: [String] = []

    init(finalStatuses: [String: RuntimeStatus]) {
        self.finalStatuses = finalStatuses
    }

    func snapshot(for projectID: String) -> RuntimeSnapshot {
        states[projectID] ?? RuntimeSnapshot()
    }

    func start(_ project: Project) throws -> RuntimeSnapshot {
        starts.append(project.id)
        let state = RuntimeSnapshot(status: .starting)
        states[project.id] = state
        return state
    }

    func waitForReady(
        projectID: String,
        timeout: Duration,
        pollInterval: Duration
    ) -> RuntimeSnapshot {
        let status = finalStatuses[projectID] ?? .ready
        let state = RuntimeSnapshot(
            status: status,
            readinessMessage: status == .ready ? "Project is ready." : "Failed before Ready."
        )
        states[projectID] = state
        return state
    }

    func stopAll() { states = [:] }
    func startedIDs() -> [String] { starts }
}
