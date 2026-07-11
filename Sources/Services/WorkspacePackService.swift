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
        do { rawData = try fileSystem.readData(at: packURL) }
        catch { throw WorkspaceError.pack("Workspace pack could not be read: \(error.localizedDescription)") }
        let pack = try decode(rawData)
        guard pack.localwrap == Self.version else {
            throw WorkspaceError.pack("Unsupported LocalWrap workspace pack version: \(pack.localwrap)")
        }
        guard !pack.projects.isEmpty else {
            throw WorkspaceError.pack("Workspace pack needs at least one project.")
        }

        var usedProjectIDs = Set<String>()
        var aliases: [String: String] = [:]
        var reviewed: [ReviewedWorkspacePackProject] = []
        for (index, raw) in pack.projects.enumerated() {
            let rawID = nonempty(raw.id) ?? nonempty(raw.name) ?? "project-\(index + 1)"
            let id = uniqueSlug(rawID, used: &usedProjectIDs)
            for alias in [raw.id, raw.name, rawID, id].compactMap({ nonempty($0) }) where aliases[alias] == nil {
                aliases[alias] = id
            }
            let relative = nonempty(raw.path) ?? "."
            guard !(relative as NSString).isAbsolutePath else {
                throw WorkspaceError.pack("Workspace project paths must be relative.")
            }
            let projectURL = canonical(root.appendingPathComponent(relative, isDirectory: true))
            guard contains(root: root, child: projectURL) else {
                throw WorkspaceError.pack("Workspace project path escapes the workspace folder: \(relative)")
            }
            guard fileSystem.isDirectory(at: projectURL) else {
                throw WorkspaceError.pack("Workspace project folder does not exist: \(relative)")
            }
            let command = raw.command.trimmingCharacters(in: .whitespacesAndNewlines)
            do { _ = try commandParser.parse(command) }
            catch { throw WorkspaceError.pack(error.localizedDescription) }
            let port = raw.port ?? 3_000
            guard (1_000...65_535).contains(port) else {
                throw WorkspaceError.pack("Workspace project port must be between 1000 and 65535.")
            }
            let url = nonempty(raw.url) ?? "http://localhost:\(port)"
            guard urlValidator.validate(url) else {
                throw WorkspaceError.pack("Workspace project \"\(raw.name ?? rawID)\" must use a local http(s) URL.")
            }
            let draft = ProjectDraft(
                id: id,
                name: nonempty(raw.name) ?? rawID,
                cwd: projectURL.path,
                command: command,
                port: port,
                url: url,
                autostart: raw.autostart ?? false,
                openOnReady: raw.openOnReady ?? true,
                dependsOn: raw.dependsOn,
                healthCheck: raw.healthCheck
            )
            let health = healthChecks.resolve(projectURL: url, healthCheck: raw.healthCheck)
            guard health.isValid else { throw WorkspaceError.pack(health.error ?? "Invalid health check.") }
            reviewed.append(ReviewedWorkspacePackProject(
                id: id,
                name: draft.name ?? rawID,
                path: relativePath(from: root, to: projectURL),
                draft: draft
            ))
        }

        let projectIDs = Set(reviewed.map(\.id))
        reviewed = try reviewed.map { project in
            var project = project
            let dependencies = unique(project.draft.dependsOn ?? []).map { aliases[$0] ?? $0 }
            if let unknown = dependencies.first(where: { !projectIDs.contains($0) }) {
                throw WorkspaceError.pack("Workspace project \"\(project.name)\" depends on unknown project: \(unknown)")
            }
            project.draft.dependsOn = dependencies.isEmpty ? nil : dependencies
            return project
        }

        var usedProfileIDs = Set<String>()
        var profiles: [ReviewedWorkspacePackProfile] = []
        for (index, raw) in (pack.workspaces ?? []).enumerated() {
            let rawID = nonempty(raw.id) ?? nonempty(raw.name) ?? "workspace-\(index + 1)"
            let ids = unique(raw.projects ?? []).map { aliases[$0] ?? $0 }.filter(projectIDs.contains)
            guard !ids.isEmpty else { continue }
            profiles.append(ReviewedWorkspacePackProfile(
                id: uniqueSlug(rawID, used: &usedProfileIDs),
                name: nonempty(raw.name) ?? rawID,
                projectIDs: ids
            ))
        }
        let name = nonempty(pack.name) ?? root.lastPathComponent.nonempty ?? "Workspace"
        if profiles.isEmpty {
            profiles = [ReviewedWorkspacePackProfile(
                id: "default",
                name: name,
                projectIDs: reviewed.map(\.id)
            )]
        }
        return ReviewedWorkspacePack(
            name: name,
            rootURL: root,
            packURL: packURL,
            projects: reviewed,
            profiles: profiles
        )
    }

    func importReviewed(_ pack: ReviewedWorkspacePack, into store: ProjectStore) throws -> NativeStoreDocument {
        try store.importWorkspacePack(pack)
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
        var packProjects: [WorkspacePackProject] = []
        var skipped: [WorkspacePackSkippedProject] = []
        for project in projects {
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
        for index in packProjects.indices {
            guard let savedID = idMap.first(where: { $0.value == packProjects[index].id })?.key,
                  let saved = projects.first(where: { $0.id == savedID }) else { continue }
            let dependencies = unique(saved.dependsOn ?? []).compactMap { idMap[$0] }
            packProjects[index].dependsOn = dependencies.isEmpty ? nil : dependencies
        }
        var usedProfileIDs = Set<String>()
        var packProfiles: [WorkspacePackProfile] = []
        for profile in workspace.savedWorkspaces {
            let ids = unique(profile.projectIds.compactMap { idMap[$0] })
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
        return WorkspacePackExportResult(
            pack: WorkspacePackV1(
                localwrap: Self.version,
                name: packName,
                projects: packProjects,
                workspaces: packProfiles
            ),
            skippedProjects: skipped
        )
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
        let data = try encoder.encode(result.pack) + Data([0x0A])
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

    private func decode(_ data: Data) throws -> WorkspacePackV1 {
        do {
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WorkspaceError.pack("Workspace pack must be a JSON object.")
            }
            if object["localwrap"] == nil { object["localwrap"] = object["version"] ?? Self.version }
            let normalized = try JSONSerialization.data(withJSONObject: object)
            return try decoder.decode(WorkspacePackV1.self, from: normalized)
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.pack("Workspace pack is not valid JSON: \(error.localizedDescription)")
        }
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

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
