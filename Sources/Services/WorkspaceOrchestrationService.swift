import Foundation

protocol WorkspaceRuntimeControlling: Sendable {
    func snapshot(for projectID: String) async -> RuntimeSnapshot
    func start(_ project: Project) async throws -> RuntimeSnapshot
    func waitForReady(projectID: String, timeout: Duration, pollInterval: Duration) async -> RuntimeSnapshot
    func stopAll() async
}

extension RuntimeService: WorkspaceRuntimeControlling {}

actor WorkspaceOrchestrationService {
    private let runtime: any WorkspaceRuntimeControlling
    private let doctor: WorkspaceDoctorService
    private let graph: WorkspaceGraph
    private var operationID: UUID?

    init(
        runtime: any WorkspaceRuntimeControlling,
        doctor: WorkspaceDoctorService = WorkspaceDoctorService(),
        graph: WorkspaceGraph = WorkspaceGraph()
    ) {
        self.runtime = runtime
        self.doctor = doctor
        self.graph = graph
    }

    var isOperating: Bool { operationID != nil }

    func start(
        projects: [Project],
        workspace: WorkspaceState,
        target: WorkspaceTarget? = nil,
        startReadyOnly: Bool,
        waitTimeout: Duration = .seconds(35)
    ) async throws -> (WorkspaceDiagnosis, WorkspaceOperationSummary) {
        guard operationID == nil else { throw WorkspaceError.operationInProgress }
        let currentOperation = UUID()
        operationID = currentOperation
        defer { if operationID == currentOperation { operationID = nil } }

        let snapshots = await snapshots(for: projects)
        let diagnosis = try doctor.diagnose(
            projects: projects,
            workspace: workspace,
            target: target,
            runtimes: snapshots
        )
        let targetIDs = Set(diagnosis.target.projectIDs)
        let includedIDs = startReadyOnly ? Set(diagnosis.startableProjectIDs) : targetIDs
        let targetProjects = projects.filter { targetIDs.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: targetProjects.map { ($0.id, $0) })
        let diagnosisByID = Dictionary(uniqueKeysWithValues: diagnosis.projects.map { ($0.id, $0) })
        var readyIDs = Set(snapshots.filter { $0.value.status == .ready }.map(\.key))
        var results: [WorkspaceOperationResult] = []

        for project in graph.stableTopologicalOrder(targetProjects) {
            guard operationID == currentOperation else { break }
            if !includedIDs.contains(project.id) || diagnosis.blockedProjectIDs.contains(project.id) {
                let detail = diagnosisByID[project.id]?.summary ?? "Workspace Doctor blocked this project."
                results.append(result(project, .blocked, "workspace-doctor-blocked", detail))
                continue
            }
            let dependencies = (project.dependsOn ?? []).filter { byID[$0] != nil }
            let notReady = dependencies.filter { !readyIDs.contains($0) }
            if !notReady.isEmpty {
                let names = notReady.map { byID[$0]?.name ?? $0 }
                results.append(WorkspaceOperationResult(
                    projectID: project.id,
                    projectName: project.name,
                    status: .skipped,
                    reason: "dependency-not-ready",
                    message: "Waiting for \(names.joined(separator: ", ")).",
                    blockedByProjectIDs: notReady,
                    blockedByProjectNames: names
                ))
                continue
            }
            let existing = await runtime.snapshot(for: project.id)
            if existing.status.isActive {
                if existing.status == .ready { readyIDs.insert(project.id) }
                results.append(result(
                    project,
                    .skipped,
                    "already-active",
                    existing.status == .ready ? "Already ready." : "Already active."
                ))
                continue
            }
            do {
                _ = try await runtime.start(project)
                let final = await runtime.waitForReady(
                    projectID: project.id,
                    timeout: waitTimeout,
                    pollInterval: .milliseconds(50)
                )
                guard operationID == currentOperation else { break }
                if final.status == .ready {
                    readyIDs.insert(project.id)
                    results.append(result(project, .started, nil, "Project became Ready."))
                } else {
                    results.append(result(
                        project,
                        .failed,
                        "not-ready",
                        final.readinessMessage ?? final.error ?? "Project did not become Ready."
                    ))
                }
            } catch {
                results.append(result(project, .failed, "start-failed", error.localizedDescription))
            }
        }
        return (diagnosis, WorkspaceOperationSummary(results: results))
    }

    func stopAll() async {
        operationID = nil
        await runtime.stopAll()
    }

    private func snapshots(for projects: [Project]) async -> [String: RuntimeSnapshot] {
        var result: [String: RuntimeSnapshot] = [:]
        for project in projects { result[project.id] = await runtime.snapshot(for: project.id) }
        return result
    }

    private func result(
        _ project: Project,
        _ status: WorkspaceOperationItemStatus,
        _ reason: String?,
        _ message: String
    ) -> WorkspaceOperationResult {
        WorkspaceOperationResult(
            projectID: project.id,
            projectName: project.name,
            status: status,
            reason: reason,
            message: message,
            blockedByProjectIDs: [],
            blockedByProjectNames: []
        )
    }
}
