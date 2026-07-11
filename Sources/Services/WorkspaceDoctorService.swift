import Foundation

final class WorkspaceDoctorService: @unchecked Sendable {
    private let projectDoctor: ProjectDoctorService
    private let fileSystem: any DoctorFileSystem
    private let portSuggester: PortSuggestionService
    private let healthChecks: HealthCheckResolver
    private let graph: WorkspaceGraph
    private let now: @Sendable () -> String

    init(
        projectDoctor: ProjectDoctorService = ProjectDoctorService(),
        fileSystem: any DoctorFileSystem = LocalDoctorFileSystem(),
        portSuggester: PortSuggestionService = PortSuggestionService(),
        healthChecks: HealthCheckResolver = HealthCheckResolver(),
        graph: WorkspaceGraph = WorkspaceGraph(),
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.projectDoctor = projectDoctor
        self.fileSystem = fileSystem
        self.portSuggester = portSuggester
        self.healthChecks = healthChecks
        self.graph = graph
        self.now = now
    }

    func resolveTarget(
        projects: [Project],
        workspace: WorkspaceState,
        requested: WorkspaceTarget? = nil
    ) throws -> ResolvedWorkspaceTarget {
        let validIDs = Set(projects.map(\.id))
        if case .profile(let profileID) = requested {
            guard let profile = workspace.savedWorkspaces.first(where: { $0.id == profileID }) else {
                throw WorkspaceError.profileNotFound
            }
            return ResolvedWorkspaceTarget(
                kind: .profile,
                profileID: profile.id,
                name: profile.name,
                projectIDs: profile.projectIds.filter(validIDs.contains)
            )
        }
        if requested == .lastRunning || requested == nil {
            let ids = workspace.lastRunningProjectIds.filter(validIDs.contains)
            if !ids.isEmpty {
                return ResolvedWorkspaceTarget(
                    kind: .lastRunning,
                    profileID: nil,
                    name: "Last running workspace",
                    projectIDs: ids
                )
            }
        }
        return ResolvedWorkspaceTarget(
            kind: .allProjects,
            profileID: nil,
            name: "Saved projects",
            projectIDs: projects.map(\.id)
        )
    }

    func diagnose(
        projects: [Project],
        workspace: WorkspaceState,
        target requested: WorkspaceTarget? = nil,
        runtimes: [String: RuntimeSnapshot] = [:]
    ) throws -> WorkspaceDiagnosis {
        let target = try resolveTarget(projects: projects, workspace: workspace, requested: requested)
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let selected = target.projectIDs.compactMap { byID[$0] }
        guard !selected.isEmpty else { return emptyDiagnosis(target) }

        var issues = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, [WorkspaceIssue]()) })
        for project in selected {
            let diagnosis = projectDoctor.diagnose(ProjectDraft(project: project), checkPortAvailability: false)
            for message in diagnosis.validation.messages {
                issues[project.id, default: []].append(WorkspaceIssue(
                    severity: message.severity == .error ? .blocker : .warning,
                    check: check(for: message.field),
                    code: message.code,
                    message: message.message
                ))
            }
            if let environmentIssue = environmentIssue(for: project) {
                issues[project.id, default: []].append(environmentIssue)
            }
            let resolution = healthChecks.resolve(project)
            if !resolution.isValid {
                issues[project.id, default: []].append(WorkspaceIssue(
                    severity: .blocker,
                    check: .startup,
                    code: "health-check-invalid",
                    message: resolution.error ?? "Health check is invalid."
                ))
            }
        }

        addPortIssues(selected, runtimes: runtimes, issues: &issues)
        addGraphIssues(selected, allProjects: projects, issues: &issues)

        let projectDiagnoses = selected.map { project -> WorkspaceProjectDiagnosis in
            let projectIssues = issues[project.id] ?? []
            let dependencies = (project.dependsOn ?? []).compactMap { byID[$0]?.name ?? $0 }
            let status: WorkspaceProjectStatus = projectIssues.contains { $0.severity == .blocker }
                ? .blocked
                : projectIssues.contains { $0.severity == .warning } ? .attention : .ready
            let summary = projectIssues.first { $0.severity == .blocker }?.message
                ?? projectIssues.first { $0.severity == .warning }?.message
                ?? (dependencies.isEmpty ? "Ready to start." : "Waits for \(dependencies.joined(separator: ", ")).")
            return WorkspaceProjectDiagnosis(
                id: project.id,
                name: project.name,
                status: status,
                summary: summary,
                dependencyNames: dependencies,
                issues: projectIssues
            )
        }
        let blockers = projectDiagnoses.filter { $0.status == .blocked }
        let warnings = projectDiagnoses.filter { $0.status == .attention }
        let ready = projectDiagnoses.filter { $0.status == .ready }
        let status: WorkspaceDoctorStatus = !blockers.isEmpty ? .blocked : !warnings.isEmpty ? .attention : .ready
        let summary: String
        switch status {
        case .blocked: summary = "\(blockers.count) project(s) blocked before first green run."
        case .attention: summary = "\(warnings.count) project(s) need attention before first green run."
        case .ready: summary = "Workspace looks ready to start."
        case .empty: summary = "No saved projects to diagnose."
        }
        let checks = WorkspaceCheckID.allCases.map { checkID -> WorkspaceDoctorCheck in
            if checkID == .projects {
                return WorkspaceDoctorCheck(
                    id: checkID,
                    status: .pass,
                    message: "\(selected.count) project(s) selected."
                )
            }
            let checkIssues = projectDiagnoses.flatMap(\.issues).filter { $0.check == checkID }
            let failures = checkIssues.count { $0.severity == .blocker }
            let warningCount = checkIssues.count { $0.severity == .warning }
            if failures > 0 {
                return WorkspaceDoctorCheck(id: checkID, status: .fail, message: "\(failures) blocker(s) found.")
            }
            if warningCount > 0 {
                return WorkspaceDoctorCheck(id: checkID, status: .warn, message: "\(warningCount) warning(s) found.")
            }
            return WorkspaceDoctorCheck(id: checkID, status: .pass, message: "Ready.")
        }
        return WorkspaceDiagnosis(
            status: status,
            summary: summary,
            updatedAt: now(),
            target: target,
            totals: WorkspaceDiagnosisTotals(
                projects: projectDiagnoses.count,
                ready: ready.count,
                warnings: warnings.count,
                blockers: blockers.count
            ),
            startableProjectIDs: projectDiagnoses.filter { $0.status != .blocked }.map(\.id),
            blockedProjectIDs: blockers.map(\.id),
            checks: checks,
            projects: projectDiagnoses
        )
    }

    func parseEnvironmentKeys(_ contents: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard isEnvironmentKey(key), seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }

    private func environmentIssue(for project: Project) -> WorkspaceIssue? {
        let directory = URL(fileURLWithPath: project.cwd, isDirectory: true)
        let example = directory.appendingPathComponent(".env.example")
        guard fileSystem.fileExists(at: example),
              let data = try? fileSystem.readData(at: example),
              let contents = String(data: data, encoding: .utf8) else { return nil }
        let expected = parseEnvironmentKeys(contents)
        guard !expected.isEmpty else { return nil }
        let environment = directory.appendingPathComponent(".env")
        var actual: [String] = []
        if fileSystem.fileExists(at: environment),
           let data = try? fileSystem.readData(at: environment),
           let contents = String(data: data, encoding: .utf8) {
            actual = parseEnvironmentKeys(contents)
        }
        let actualSet = Set(actual)
        let missing = expected.filter { !actualSet.contains($0) }
        guard !missing.isEmpty else { return nil }
        let preview = missing.prefix(3).joined(separator: ", ")
        let suffix = missing.count > 3 ? ", +\(missing.count - 3) more" : ""
        return WorkspaceIssue(
            severity: .warning,
            check: .environment,
            code: actual.isEmpty ? "env-file-missing" : "env-vars-missing",
            message: actual.isEmpty
                ? "Missing .env for \(missing.count) expected value(s): \(preview)\(suffix)."
                : "Missing env value(s): \(preview)\(suffix)."
        )
    }

    private func addPortIssues(
        _ projects: [Project],
        runtimes: [String: RuntimeSnapshot],
        issues: inout [String: [WorkspaceIssue]]
    ) {
        let grouped = Dictionary(grouping: projects.filter { (1_000...65_535).contains($0.port) }, by: \.port)
        for (port, group) in grouped where group.count > 1 {
            let names = group.map(\.name).joined(separator: ", ")
            for project in group {
                issues[project.id, default: []].append(WorkspaceIssue(
                    severity: .blocker,
                    check: .ports,
                    code: "port-duplicate",
                    message: "Port \(port) is assigned to multiple projects: \(names)."
                ))
            }
        }
        for project in projects where grouped[project.port]?.count == 1 {
            guard runtimes[project.id]?.status.isActive != true,
                  !portSuggester.isAvailable(project.port) else { continue }
            issues[project.id, default: []].append(WorkspaceIssue(
                severity: .warning,
                check: .ports,
                code: "port-busy",
                message: "Port \(project.port) appears to be in use."
            ))
        }
    }

    private func addGraphIssues(
        _ selected: [Project],
        allProjects: [Project],
        issues: inout [String: [WorkspaceIssue]]
    ) {
        let allByID = Dictionary(uniqueKeysWithValues: allProjects.map { ($0.id, $0) })
        let selectedByID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        for project in selected {
            for dependencyID in project.dependsOn ?? [] {
                if allByID[dependencyID] == nil {
                    issues[project.id, default: []].append(WorkspaceIssue(
                        severity: .blocker,
                        check: .startup,
                        code: "dependency-missing",
                        message: "Dependency \(dependencyID) is not a saved project."
                    ))
                } else if selectedByID[dependencyID] == nil {
                    issues[project.id, default: []].append(WorkspaceIssue(
                        severity: .blocker,
                        check: .startup,
                        code: "dependency-outside-workspace",
                        message: "Dependency \(allByID[dependencyID]?.name ?? dependencyID) is not in this workspace."
                    ))
                }
            }
        }
        for projectID in graph.cycleProjectIDs(selected) {
            issues[projectID, default: []].append(WorkspaceIssue(
                severity: .blocker,
                check: .startup,
                code: "dependency-cycle",
                message: "Dependency cycle detected."
            ))
        }
        var changed = true
        while changed {
            changed = false
            for project in selected {
                guard !(issues[project.id] ?? []).contains(where: { $0.code == "dependency-cycle" }) else { continue }
                let blocked = (project.dependsOn ?? []).filter { dependencyID in
                    (issues[dependencyID] ?? []).contains { $0.severity == .blocker }
                }
                guard !blocked.isEmpty,
                      !(issues[project.id] ?? []).contains(where: { $0.code == "dependency-blocked" }) else { continue }
                let names = blocked.map { selectedByID[$0]?.name ?? $0 }.joined(separator: ", ")
                issues[project.id, default: []].append(WorkspaceIssue(
                    severity: .blocker,
                    check: .startup,
                    code: "dependency-blocked",
                    message: "Blocked by \(names)."
                ))
                changed = true
            }
        }
    }

    private func emptyDiagnosis(_ target: ResolvedWorkspaceTarget) -> WorkspaceDiagnosis {
        WorkspaceDiagnosis(
            status: .empty,
            summary: "No saved projects to diagnose. Next: import a workspace pack or add a project.",
            updatedAt: now(),
            target: target,
            totals: WorkspaceDiagnosisTotals(projects: 0, ready: 0, warnings: 0, blockers: 0),
            startableProjectIDs: [],
            blockedProjectIDs: [],
            checks: WorkspaceCheckID.allCases.map {
                WorkspaceDoctorCheck(
                    id: $0,
                    status: $0 == .projects ? .fail : .pending,
                    message: "No projects selected."
                )
            },
            projects: []
        )
    }

    private func check(for field: ProjectField) -> WorkspaceCheckID {
        switch field {
        case .name: .projects
        case .cwd: .directories
        case .command: .commands
        case .dependencies: .dependencies
        case .port: .ports
        case .url: .urls
        }
    }

    private func isEnvironmentKey(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }
}
