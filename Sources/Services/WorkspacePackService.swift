import Foundation

protocol WorkspacePackFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func createDirectory(at url: URL) throws
    func writeData(_ data: Data, to url: URL) throws
    func replaceItem(at destination: URL, with source: URL) throws
    func removeItem(at url: URL) throws
}

struct LocalWorkspacePackFileSystem: WorkspacePackFileSystem {
    func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func isDirectory(at url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
    func readData(at url: URL) throws -> Data { try Data(contentsOf: url) }
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func writeData(_ data: Data, to url: URL) throws { try data.write(to: url) }
    func replaceItem(at destination: URL, with source: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: source)
        } else {
            try manager.moveItem(at: source, to: destination)
        }
    }
    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
}

private struct WorkspacePackValidationFileSystem: WorkspacePackFileSystem {
    let base: any WorkspacePackFileSystem
    let manifestURL: URL
    let manifestData: Data

    private func isManifest(_ url: URL) -> Bool {
        url.standardizedFileURL.path == manifestURL.standardizedFileURL.path
    }

    func fileExists(at url: URL) -> Bool {
        isManifest(url) || base.fileExists(at: url)
    }

    func isDirectory(at url: URL) -> Bool {
        isManifest(url) ? false : base.isDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        isManifest(url) ? manifestData : try base.readData(at: url)
    }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func writeData(_ data: Data, to url: URL) throws { try base.writeData(data, to: url) }
    func replaceItem(at destination: URL, with source: URL) throws {
        try base.replaceItem(at: destination, with: source)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
}

final class WorkspacePackService: @unchecked Sendable {
    static let version = 1
    static let candidates = [".localwrap/workspace.json", "localwrap.json"]

    private let fileSystem: any WorkspacePackFileSystem
    private let commandParser: CommandParser
    private let urlValidator: LocalURLValidator
    private let healthChecks: HealthCheckResolver
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init(
        fileSystem: any WorkspacePackFileSystem = LocalWorkspacePackFileSystem(),
        commandParser: CommandParser = CommandParser(),
        urlValidator: LocalURLValidator = LocalURLValidator(),
        healthChecks: HealthCheckResolver = HealthCheckResolver()
    ) {
        self.fileSystem = fileSystem
        self.commandParser = commandParser
        self.urlValidator = urlValidator
        self.healthChecks = healthChecks
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    func discover(in rootURL: URL) throws -> URL? {
        let root = canonical(rootURL)
        guard fileSystem.isDirectory(at: root) else {
            throw WorkspaceError.pack("Workspace folder does not exist: \(root.path)")
        }
        return Self.candidates.lazy.map { root.appendingPathComponent($0) }
            .first { fileSystem.fileExists(at: $0) && !fileSystem.isDirectory(at: $0) }
    }

    func review(rootURL: URL, packURL requestedPackURL: URL? = nil) throws -> ReviewedWorkspacePack {
        let result = try inspect(rootURL: rootURL, packURL: requestedPackURL)
        guard let pack = result.pack, result.blockers.isEmpty else {
            throw WorkspaceError.pack(
                result.blockers.first?.message ?? "Workspace pack could not be validated."
            )
        }
        return pack
    }

    func inspect(
        rootURL: URL,
        packURL requestedPackURL: URL? = nil,
        projects savedProjects: [Project] = [],
        workspace savedWorkspace: WorkspaceState = .empty
    ) throws -> WorkspacePackReview {
        let root = canonical(rootURL)
        guard fileSystem.isDirectory(at: root) else {
            throw WorkspaceError.pack("Workspace folder does not exist: \(root.path)")
        }
        guard let packURL = try requestedPackURL.map(canonical) ?? discover(in: root) else {
            throw WorkspaceError.pack("No LocalWrap workspace pack found in that folder.")
        }
        guard contains(root: root, child: packURL) else {
            throw WorkspaceError.pack("Workspace pack must live inside the selected folder.")
        }

        let rawData: Data
        do {
            rawData = try fileSystem.readData(at: packURL)
        } catch {
            throw WorkspaceError.pack("Workspace pack could not be read: \(error.localizedDescription)")
        }

        let decoded: WorkspacePackV1
        do {
            decoded = try decode(rawData)
        } catch {
            return invalidReview(
                root: root,
                packURL: packURL,
                message: error.localizedDescription
            )
        }

        var issues = schemaIssues(in: rawData)
        if decoded.localwrap != Self.version {
            issues.append(issue(
                "unsupported-version",
                .blocker,
                scope: "Manifest",
                field: "localwrap",
                message: "Unsupported LocalWrap workspace pack version: \(decoded.localwrap)."
            ))
        }
        if decoded.projects.isEmpty {
            issues.append(issue(
                "projects-required",
                .blocker,
                scope: "Manifest",
                field: "projects",
                message: "Workspace pack needs at least one project."
            ))
        }

        var aliases: [String: String] = [:]
        var usedProjectIDs = Set<String>()
        var candidates: [ManifestProjectCandidate] = []

        for (index, raw) in decoded.projects.enumerated() {
            let rawID = nonempty(raw.id) ?? nonempty(raw.name) ?? "project-\(index + 1)"
            let baseID = slug(rawID)
            if usedProjectIDs.contains(baseID) {
                issues.append(issue(
                    "duplicate-project-id",
                    .blocker,
                    scope: "Project \(rawID)",
                    field: "id",
                    message: "Project identifiers must be unique after normalization: \(baseID)."
                ))
            }
            let id = uniqueSlug(rawID, used: &usedProjectIDs)
            let name = nonempty(raw.name) ?? rawID
            let scope = "Project \(name)"
            for alias in [raw.id, raw.name, rawID, id].compactMap({ nonempty($0) }) {
                if let existing = aliases[alias], existing != id {
                    issues.append(issue(
                        "ambiguous-project-reference",
                        .blocker,
                        scope: scope,
                        field: "id",
                        message: "Project reference \"\(alias)\" is ambiguous. Give every project a unique id."
                    ))
                } else {
                    aliases[alias] = id
                }
            }

            let relative = nonempty(raw.path) ?? "."
            let isAbsolute = (relative as NSString).isAbsolutePath
            let projectURL = canonical(root.appendingPathComponent(relative, isDirectory: true))
            if isAbsolute {
                issues.append(issue(
                    "absolute-project-path",
                    .blocker,
                    scope: scope,
                    field: "path",
                    message: "Workspace project paths must be relative to the repository root."
                ))
            } else if !contains(root: root, child: projectURL) {
                issues.append(issue(
                    "project-path-escape",
                    .blocker,
                    scope: scope,
                    field: "path",
                    message: "Project path escapes the repository root: \(relative)."
                ))
            } else if !fileSystem.isDirectory(at: projectURL) {
                issues.append(issue(
                    "project-folder-missing",
                    .blocker,
                    scope: scope,
                    field: "path",
                    message: "Project folder does not exist: \(relative)."
                ))
            }

            let command = raw.command.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                _ = try commandParser.parse(command)
            } catch {
                issues.append(issue(
                    "command-invalid",
                    .blocker,
                    scope: scope,
                    field: "command",
                    message: error.localizedDescription
                ))
            }

            let port = raw.port ?? 3_000
            if !(1_000...65_535).contains(port) {
                issues.append(issue(
                    "port-invalid",
                    .blocker,
                    scope: scope,
                    field: "port",
                    message: "Port must be between 1000 and 65535."
                ))
            }

            let url = nonempty(raw.url) ?? "http://localhost:\(port)"
            if !urlValidator.validate(url) {
                issues.append(issue(
                    "url-invalid",
                    .blocker,
                    scope: scope,
                    field: "url",
                    message: "URL must be local http(s) on localhost, 127.0.0.1, or ::1."
                ))
            } else if urlValidator.port(in: url) != port {
                issues.append(issue(
                    "url-port-mismatch",
                    .warning,
                    scope: scope,
                    field: "url",
                    message: "URL port does not match the configured project port."
                ))
            }

            let health = healthChecks.resolve(projectURL: url, healthCheck: raw.healthCheck)
            if !health.isValid {
                issues.append(issue(
                    "health-check-invalid",
                    .blocker,
                    scope: scope,
                    field: "healthCheck",
                    message: health.error ?? "Health check is invalid."
                ))
            }

            let draft = ProjectDraft(
                id: id,
                name: name,
                cwd: projectURL.path,
                command: command,
                port: port,
                url: url,
                autostart: raw.autostart ?? false,
                openOnReady: raw.openOnReady ?? true,
                dependsOn: raw.dependsOn,
                healthCheck: raw.healthCheck
            )
            candidates.append(ManifestProjectCandidate(
                id: id,
                name: name,
                path: isAbsolute || !contains(root: root, child: projectURL)
                    ? relative
                    : relativePath(from: root, to: projectURL),
                draft: draft
            ))
        }

        let projectIDs = Set(candidates.map(\.id))
        for index in candidates.indices {
            let scope = "Project \(candidates[index].name)"
            let dependencies = unique(candidates[index].draft.dependsOn ?? []).map { aliases[$0] ?? $0 }
            for unknown in dependencies where !projectIDs.contains(unknown) {
                issues.append(issue(
                    "dependency-unknown",
                    .blocker,
                    scope: scope,
                    field: "dependsOn",
                    message: "Dependency does not match a project in this manifest: \(unknown)."
                ))
            }
            let knownDependencies = dependencies.filter(projectIDs.contains)
            candidates[index].draft.dependsOn = knownDependencies.isEmpty ? nil : knownDependencies
        }

        let portGroups = Dictionary(grouping: candidates, by: { $0.draft.port })
        for (port, matches) in portGroups where matches.count > 1 {
            issues.append(issue(
                "port-conflict",
                .blocker,
                scope: "Projects",
                field: "port",
                message: "Port \(port) is assigned to multiple projects: \(matches.map(\.name).sorted().joined(separator: ", "))."
            ))
        }
        let cycleIDs = dependencyCycleIDs(candidates)
        if !cycleIDs.isEmpty {
            issues.append(issue(
                "dependency-cycle",
                .blocker,
                scope: "Projects",
                field: "dependsOn",
                message: "Dependency cycle includes: \(cycleIDs.sorted().joined(separator: ", "))."
            ))
        }

        var usedProfileIDs = Set<String>()
        var profiles: [ReviewedWorkspacePackProfile] = []
        for (index, raw) in (decoded.workspaces ?? []).enumerated() {
            let rawID = nonempty(raw.id) ?? nonempty(raw.name) ?? "workspace-\(index + 1)"
            let baseID = slug(rawID)
            let name = nonempty(raw.name) ?? rawID
            let scope = "Workspace \(name)"
            if usedProfileIDs.contains(baseID) {
                issues.append(issue(
                    "duplicate-workspace-id",
                    .blocker,
                    scope: scope,
                    field: "id",
                    message: "Workspace identifiers must be unique after normalization: \(baseID)."
                ))
            }
            let id = uniqueSlug(rawID, used: &usedProfileIDs)
            let requested = unique(raw.projects ?? [])
            let resolved = requested.map { aliases[$0] ?? $0 }
            for unknown in resolved where !projectIDs.contains(unknown) {
                issues.append(issue(
                    "workspace-project-unknown",
                    .blocker,
                    scope: scope,
                    field: "projects",
                    message: "Workspace references an unknown project: \(unknown)."
                ))
            }
            let validIDs = resolved.filter(projectIDs.contains)
            if validIDs.isEmpty {
                issues.append(issue(
                    "workspace-projects-required",
                    .blocker,
                    scope: scope,
                    field: "projects",
                    message: "Workspace must reference at least one manifest project."
                ))
            }
            profiles.append(ReviewedWorkspacePackProfile(
                id: id,
                name: name,
                projectIDs: validIDs
            ))
        }

        let name = nonempty(decoded.name) ?? root.lastPathComponent.nonempty ?? "Workspace"
        if profiles.isEmpty, !candidates.isEmpty {
            profiles = [ReviewedWorkspacePackProfile(
                id: "default",
                name: name,
                projectIDs: candidates.map(\.id)
            )]
        }

        let reviewedProjects = candidates.map {
            ReviewedWorkspacePackProject(
                id: $0.id,
                name: $0.name,
                path: $0.path,
                draft: $0.draft
            )
        }
        let changePlan = plannedChanges(
            projects: reviewedProjects,
            profiles: profiles,
            packPath: packURL.path,
            savedProjects: savedProjects,
            savedWorkspace: savedWorkspace
        )
        issues.append(contentsOf: changePlan.issues)
        let hasBlockers = issues.contains { $0.severity == .blocker }
        let reviewedPack = hasBlockers ? nil : ReviewedWorkspacePack(
            name: name,
            rootURL: root,
            packURL: packURL,
            projects: reviewedProjects,
            profiles: profiles
        )

        return WorkspacePackReview(
            name: name,
            rootURL: root,
            packURL: packURL,
            version: decoded.localwrap,
            projects: candidates.map {
                WorkspacePackReviewProject(
                    id: $0.id,
                    name: $0.name,
                    path: $0.path,
                    command: $0.draft.command,
                    port: $0.draft.port,
                    url: $0.draft.url,
                    dependsOn: $0.draft.dependsOn ?? [],
                    healthCheck: $0.draft.healthCheck
                )
            },
            profiles: profiles.map {
                WorkspacePackReviewProfile(id: $0.id, name: $0.name, projectIDs: $0.projectIDs)
            },
            issues: issues,
            changes: changePlan.changes,
            pack: reviewedPack
        )
    }

    func importReviewed(_ pack: ReviewedWorkspacePack, into store: ProjectStore) throws -> NativeStoreDocument {
        try store.importWorkspacePack(pack)
    }

    func importReviewed(_ review: WorkspacePackReview, into store: ProjectStore) throws -> NativeStoreDocument {
        guard review.canImport, review.pack != nil else {
            throw WorkspaceError.pack(
                review.blockers.first?.message ?? "Workspace manifest is not ready to import."
            )
        }
        let current = try store.load()
        let fresh = try inspect(
            rootURL: review.rootURL,
            packURL: review.packURL,
            projects: current.projects,
            workspace: current.workspace
        )
        guard fresh == review, let pack = fresh.pack else {
            throw WorkspaceError.pack(
                "The manifest or saved LocalWrap configuration changed after review. Review it again before importing."
            )
        }
        return try store.importWorkspacePack(pack)
    }

    func buildExport(
        rootURL: URL,
        projects: [Project],
        workspace: WorkspaceState,
        name: String? = nil
    ) throws -> WorkspacePackExportResult {
        let root = canonical(rootURL)
        guard fileSystem.isDirectory(at: root) else {
            throw WorkspaceError.pack("Workspace folder does not exist: \(root.path)")
        }
        var usedProjectIDs = Set<String>()
        var idMap: [String: String] = [:]
        var savedProjectByID: [String: Project] = [:]
        var packProjects: [WorkspacePackProject] = []
        var skipped: [WorkspacePackSkippedProject] = []
        let orderedProjects = projects.sorted { lhs, rhs in
            projectExportKey(lhs) < projectExportKey(rhs)
        }
        for project in orderedProjects {
            let cwd = canonical(URL(fileURLWithPath: project.cwd, isDirectory: true))
            guard contains(root: root, child: cwd) else {
                skipped.append(WorkspacePackSkippedProject(
                    id: project.id,
                    name: project.name,
                    reason: "outside-workspace-folder"
                ))
                continue
            }
            let sourceID = project.source?.type == "workspace-pack" ? project.source?.packProjectId : nil
            let packID = uniqueSlug(sourceID ?? project.name, used: &usedProjectIDs)
            idMap[project.id] = packID
            savedProjectByID[project.id] = project
            packProjects.append(WorkspacePackProject(
                id: packID,
                name: project.name,
                path: relativePath(from: root, to: cwd),
                command: project.command,
                port: project.port,
                url: project.url,
                autostart: project.autostart,
                openOnReady: project.openOnReady,
                healthCheck: project.healthCheck
            ))
        }
        guard !packProjects.isEmpty else {
            throw WorkspaceError.pack("No saved projects live inside that workspace folder.")
        }
        let savedIDByPackID = Dictionary(uniqueKeysWithValues: idMap.map { ($0.value, $0.key) })
        for index in packProjects.indices {
            guard let packID = packProjects[index].id,
                  let savedID = savedIDByPackID[packID],
                  let saved = savedProjectByID[savedID] else { continue }
            let dependencies = unique(saved.dependsOn ?? []).compactMap { idMap[$0] }.sorted()
            packProjects[index].dependsOn = dependencies.isEmpty ? nil : dependencies
        }
        packProjects.sort { ($0.id ?? "") < ($1.id ?? "") }
        var usedProfileIDs = Set<String>()
        var packProfiles: [WorkspacePackProfile] = []
        let orderedProfiles = workspace.savedWorkspaces.sorted { lhs, rhs in
            profileExportKey(lhs) < profileExportKey(rhs)
        }
        for profile in orderedProfiles {
            let ids = unique(profile.projectIds.compactMap { idMap[$0] }).sorted()
            guard !ids.isEmpty else { continue }
            let sourceID = profile.source?.type == "workspace-pack" ? profile.source?.packWorkspaceId : nil
            packProfiles.append(WorkspacePackProfile(
                id: uniqueSlug(sourceID ?? profile.name, used: &usedProfileIDs),
                name: profile.name,
                projects: ids
            ))
        }
        let packName = nonempty(name) ?? root.lastPathComponent.nonempty ?? "Workspace"
        if packProfiles.isEmpty {
            packProfiles = [WorkspacePackProfile(
                id: "default",
                name: packName,
                projects: packProjects.compactMap(\.id)
            )]
        }
        packProfiles.sort { ($0.id ?? "") < ($1.id ?? "") }
        return WorkspacePackExportResult(
            pack: WorkspacePackV1(
                localwrap: Self.version,
                name: packName,
                projects: packProjects,
                workspaces: packProfiles
            ),
            skippedProjects: skipped.sorted {
                ($0.name, $0.id, $0.reason) < ($1.name, $1.id, $1.reason)
            }
        )
    }

    func canonicalData(for pack: WorkspacePackV1) throws -> Data {
        try encoder.encode(pack) + Data([0x0A])
    }

    @discardableResult
    func writeExport(
        _ result: WorkspacePackExportResult,
        rootURL: URL,
        overwrite: Bool
    ) throws -> URL {
        let root = canonical(rootURL)
        let directory = root.appendingPathComponent(".localwrap", isDirectory: true)
        let destination = directory.appendingPathComponent("workspace.json")
        if fileSystem.fileExists(at: destination), !overwrite {
            throw WorkspaceError.pack("Workspace pack already exists. Confirm overwrite to replace it.")
        }
        let data = try validatedExportData(for: result.pack, rootURL: root, packURL: destination)
        try fileSystem.createDirectory(at: directory)
        let temporary = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try fileSystem.writeData(data, to: temporary)
            try fileSystem.replaceItem(at: destination, with: temporary)
        } catch {
            if fileSystem.fileExists(at: temporary) { try? fileSystem.removeItem(at: temporary) }
            throw error
        }
        return destination
    }

    private func validatedExportData(
        for pack: WorkspacePackV1,
        rootURL: URL,
        packURL: URL
    ) throws -> Data {
        let data = try canonicalData(for: pack)
        let validationFileSystem = WorkspacePackValidationFileSystem(
            base: fileSystem,
            manifestURL: packURL,
            manifestData: data
        )
        let validator = WorkspacePackService(
            fileSystem: validationFileSystem,
            commandParser: commandParser,
            urlValidator: urlValidator,
            healthChecks: healthChecks
        )
        let review = try validator.inspect(rootURL: rootURL, packURL: packURL)
        guard review.blockers.isEmpty else {
            let details = review.blockers
                .map { "\($0.scope): \($0.message)" }
                .joined(separator: " ")
            throw WorkspaceError.pack("Workspace export is invalid. \(details)")
        }
        return data
    }

    private func decode(_ data: Data) throws -> WorkspacePackV1 {
        do {
            guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
                throw WorkspaceError.pack("Workspace pack must be a JSON object.")
            }
            return try decoder.decode(WorkspacePackV1.self, from: data)
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.pack("Workspace pack is not valid JSON: \(error.localizedDescription)")
        }
    }

    private func invalidReview(root: URL, packURL: URL, message: String) -> WorkspacePackReview {
        WorkspacePackReview(
            name: root.lastPathComponent.nonempty ?? "Workspace",
            rootURL: root,
            packURL: packURL,
            version: nil,
            projects: [],
            profiles: [],
            issues: [issue(
                "manifest-invalid",
                .blocker,
                scope: "Manifest",
                field: nil,
                message: message
            )],
            changes: [],
            pack: nil
        )
    }

    private func issue(
        _ code: String,
        _ severity: WorkspacePackReviewSeverity,
        scope: String,
        field: String?,
        message: String
    ) -> WorkspacePackReviewIssue {
        WorkspacePackReviewIssue(
            code: code,
            severity: severity,
            scope: scope,
            field: field,
            message: message
        )
    }

    private func schemaIssues(in data: Data) -> [WorkspacePackReviewIssue] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var result: [WorkspacePackReviewIssue] = []
        appendUnknownKeys(
            in: root,
            allowed: ["localwrap", "name", "projects", "workspaces"],
            scope: "Manifest",
            issues: &result
        )
        if let projects = root["projects"] as? [Any] {
            for (index, value) in projects.enumerated() {
                guard let project = value as? [String: Any] else { continue }
                let name = (project["name"] as? String)?.nonempty
                    ?? (project["id"] as? String)?.nonempty
                    ?? "#\(index + 1)"
                appendUnknownKeys(
                    in: project,
                    allowed: [
                        "id", "name", "path", "command", "port", "url", "autostart",
                        "openOnReady", "dependsOn", "healthCheck",
                    ],
                    scope: "Project \(name)",
                    issues: &result
                )
                if let health = project["healthCheck"] as? [String: Any] {
                    appendUnknownKeys(
                        in: health,
                        allowed: ["path", "url"],
                        scope: "Project \(name)",
                        issues: &result
                    )
                }
            }
        }
        if let profiles = root["workspaces"] as? [Any] {
            for (index, value) in profiles.enumerated() {
                guard let profile = value as? [String: Any] else { continue }
                let name = (profile["name"] as? String)?.nonempty
                    ?? (profile["id"] as? String)?.nonempty
                    ?? "#\(index + 1)"
                appendUnknownKeys(
                    in: profile,
                    allowed: ["id", "name", "projects"],
                    scope: "Workspace \(name)",
                    issues: &result
                )
            }
        }
        return result
    }

    private func appendUnknownKeys(
        in object: [String: Any],
        allowed: Set<String>,
        scope: String,
        issues: inout [WorkspacePackReviewIssue]
    ) {
        let sensitive = Set([
            "authorization", "cookie", "cookies", "env", "environment", "header", "headers",
            "password", "secret", "secrets", "token", "tokens",
        ])
        for key in object.keys.sorted() where !allowed.contains(key) {
            let normalized = key.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            let secretLike = sensitive.contains(normalized)
                || sensitive.contains { normalized.contains($0) }
            issues.append(issue(
                secretLike ? "sensitive-field-unsupported" : "unknown-field",
                .blocker,
                scope: scope,
                field: key,
                message: secretLike
                    ? "Manifest field \"\(key)\" could contain secrets and is not supported."
                    : "Unknown manifest field \"\(key)\" is not supported by version 1."
            ))
        }
    }

    private func dependencyCycleIDs(_ candidates: [ManifestProjectCandidate]) -> Set<String> {
        let graph = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.id, Set($0.draft.dependsOn ?? []))
        })
        var visited = Set<String>()
        var visiting = Set<String>()
        var stack: [String] = []
        var cycles = Set<String>()

        func visit(_ id: String) {
            if let start = stack.firstIndex(of: id) {
                cycles.formUnion(stack[start...])
                return
            }
            guard !visited.contains(id) else { return }
            visiting.insert(id)
            stack.append(id)
            for dependency in (graph[id] ?? []).sorted() where visiting.contains(dependency) || !visited.contains(dependency) {
                visit(dependency)
            }
            _ = stack.popLast()
            visiting.remove(id)
            visited.insert(id)
        }
        for id in graph.keys.sorted() { visit(id) }
        return cycles
    }

    private func plannedChanges(
        projects importedProjects: [ReviewedWorkspacePackProject],
        profiles importedProfiles: [ReviewedWorkspacePackProfile],
        packPath: String,
        savedProjects: [Project],
        savedWorkspace: WorkspaceState
    ) -> ManifestChangePlan {
        let canonicalPackPath = canonical(URL(fileURLWithPath: packPath)).path
        var issues: [WorkspacePackReviewIssue] = []
        var existingByPackID: [String: Project] = [:]
        var claimedSavedIDs = Set<String>()
        var unmatchedByDirectory: [String: [ReviewedWorkspacePackProject]] = [:]

        for imported in importedProjects {
            let provenanceMatches = savedProjects.filter {
                $0.source?.type == "workspace-pack"
                    && $0.source.map { canonical(URL(fileURLWithPath: $0.packPath)).path } == canonicalPackPath
                    && $0.source?.packProjectId == imported.id
            }
            if provenanceMatches.count > 1 {
                issues.append(issue(
                    "saved-project-provenance-ambiguous",
                    .blocker,
                    scope: "Project \(imported.name)",
                    field: "id",
                    message: "Multiple saved projects claim this manifest identity. Resolve the duplicate before importing."
                ))
            } else if let existing = provenanceMatches.first {
                if !claimedSavedIDs.insert(existing.id).inserted {
                    issues.append(issue(
                        "saved-project-provenance-reused",
                        .blocker,
                        scope: "Project \(imported.name)",
                        field: "id",
                        message: "One saved project matches more than one manifest project. Resolve its provenance before importing."
                    ))
                } else {
                    existingByPackID[imported.id] = existing
                }
            } else {
                unmatchedByDirectory[canonical(URL(fileURLWithPath: imported.draft.cwd)).path, default: []]
                    .append(imported)
            }
        }

        for (directory, importedAtDirectory) in unmatchedByDirectory {
            let savedAtDirectory = savedProjects.filter {
                !claimedSavedIDs.contains($0.id)
                    && canonical(URL(fileURLWithPath: $0.cwd)).path == directory
            }
            guard !savedAtDirectory.isEmpty else { continue }
            if importedAtDirectory.count == 1, savedAtDirectory.count == 1 {
                let imported = importedAtDirectory[0]
                let saved = savedAtDirectory[0]
                existingByPackID[imported.id] = saved
                claimedSavedIDs.insert(saved.id)
            } else {
                for imported in importedAtDirectory {
                    issues.append(issue(
                        "saved-project-folder-ambiguous",
                        .blocker,
                        scope: "Project \(imported.name)",
                        field: "path",
                        message: "This folder matches multiple saved or manifest projects. Resolve the duplicate mapping before importing."
                    ))
                }
            }
        }

        var reservedIDs = Set(savedProjects.map(\.id))
        var savedIDByPackID: [String: String] = [:]
        for imported in importedProjects {
            if let existing = existingByPackID[imported.id] {
                savedIDByPackID[imported.id] = existing.id
                continue
            }
            let trimmed = (imported.draft.id ?? imported.id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "workspace-item" : trimmed
            var candidate = base
            var suffix = 2
            while reservedIDs.contains(candidate) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            reservedIDs.insert(candidate)
            savedIDByPackID[imported.id] = candidate
        }

        var changes: [WorkspacePackChange] = importedProjects.map { imported in
            let existing = existingByPackID[imported.id]
            let expectedDependencies = (imported.draft.dependsOn ?? []).compactMap {
                savedIDByPackID[$0]
            }
            let allDependenciesResolvable = expectedDependencies.count == (imported.draft.dependsOn ?? []).count
            let expectedSource = ProjectSource(
                type: "workspace-pack",
                packPath: canonicalPackPath,
                packProjectId: imported.id
            )
            let unchanged = existing.map {
                allDependenciesResolvable
                    && $0.name == imported.name
                    && $0.cwd == imported.draft.cwd
                    && $0.command == imported.draft.command
                    && $0.port == imported.draft.port
                    && $0.url == imported.draft.url
                    && $0.autostart == imported.draft.autostart
                    && $0.openOnReady == imported.draft.openOnReady
                    && ($0.dependsOn ?? []) == expectedDependencies
                    && $0.healthCheck == imported.draft.healthCheck
                    && $0.source == expectedSource
            } ?? false
            return WorkspacePackChange(
                entity: .project,
                entityID: imported.id,
                name: imported.name,
                disposition: existing == nil ? .add : (unchanged ? .unchanged : .update),
                existingSavedID: existing?.id
            )
        }

        changes += importedProfiles.map { imported in
            let matches = savedWorkspace.savedWorkspaces.filter {
                $0.source?.type == "workspace-pack"
                    && $0.source.map { canonical(URL(fileURLWithPath: $0.packPath)).path } == canonicalPackPath
                    && $0.source?.packWorkspaceId == imported.id
            }
            if matches.count > 1 {
                issues.append(issue(
                    "saved-workspace-provenance-ambiguous",
                    .blocker,
                    scope: "Workspace \(imported.name)",
                    field: "id",
                    message: "Multiple saved workspaces claim this manifest identity. Resolve the duplicate before importing."
                ))
            }
            let existing = matches.count == 1 ? matches[0] : nil
            let expectedProjectIDs = imported.projectIDs.compactMap { savedIDByPackID[$0] }
            let expectedSource = WorkspaceSource(
                type: "workspace-pack",
                packPath: canonicalPackPath,
                packWorkspaceId: imported.id
            )
            let unchanged = existing.map {
                expectedProjectIDs.count == imported.projectIDs.count
                    && $0.name == imported.name
                    && $0.projectIds == expectedProjectIDs
                    && $0.source == expectedSource
            } ?? false
            return WorkspacePackChange(
                entity: .workspace,
                entityID: imported.id,
                name: imported.name,
                disposition: existing == nil ? .add : (unchanged ? .unchanged : .update),
                existingSavedID: existing?.id
            )
        }
        return ManifestChangePlan(changes: changes, issues: issues)
    }

    private func projectExportKey(_ project: Project) -> String {
        let sourceID = project.source?.type == "workspace-pack" ? project.source?.packProjectId : nil
        return [sourceID ?? slug(project.name), canonical(URL(fileURLWithPath: project.cwd)).path, project.id]
            .joined(separator: "\u{0}")
    }

    private func profileExportKey(_ profile: WorkspaceProfile) -> String {
        let sourceID = profile.source?.type == "workspace-pack" ? profile.source?.packWorkspaceId : nil
        return [sourceID ?? slug(profile.name), profile.name, profile.id].joined(separator: "\u{0}")
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func contains(root: URL, child: URL) -> Bool {
        let rootPath = canonical(root).path
        let childPath = canonical(child).path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = canonical(root).path
        let childPath = canonical(child).path
        guard childPath != rootPath else { return "." }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func slug(_ value: String) -> String {
        let components = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(components).replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "item" : collapsed
    }

    private func uniqueSlug(_ value: String, used: inout Set<String>) -> String {
        let root = slug(value)
        var candidate = root
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(root)-\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private struct ManifestProjectCandidate {
    let id: String
    let name: String
    let path: String
    var draft: ProjectDraft
}

private struct ManifestChangePlan {
    let changes: [WorkspacePackChange]
    let issues: [WorkspacePackReviewIssue]
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
