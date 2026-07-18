import Foundation

protocol PersistenceFileSystem {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func replaceItem(at destination: URL, with source: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
}

struct LocalPersistenceFileSystem: PersistenceFileSystem {
    private let manager = FileManager.default

    func fileExists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    func replaceItem(at destination: URL, with source: URL) throws {
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: source)
        } else {
            try manager.moveItem(at: source, to: destination)
        }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try manager.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try manager.removeItem(at: url)
    }
}

struct ProjectStorePaths: Equatable, Sendable {
    let directory: URL
    let store: URL
    let backup: URL
    let electronStore: URL

    static func production(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProjectStorePaths {
        #if DEBUG
        let nativeDirectoryName = "LocalWrapNative-Debug"
        #else
        let nativeDirectoryName = "LocalWrapNative"
        #endif
        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = applicationSupport
            .appendingPathComponent(nativeDirectoryName, isDirectory: true)
        return ProjectStorePaths(
            directory: directory,
            store: directory.appendingPathComponent("store.json"),
            backup: directory.appendingPathComponent("store.json.bak"),
            electronStore: applicationSupport
                .appendingPathComponent("localwrap", isDirectory: true)
                .appendingPathComponent("projects.json")
        )
    }
}

enum PersistenceError: Error, Equatable, LocalizedError {
    case corruptNativeStore(String)
    case invalidLegacyStore(String)
    case unsupportedSchema(Int)
    case projectNotFound(String)
    case invalidProject(String)
    case backupUnavailable
    case corruptBackup(String)
    case workspaceNotFound(String)
    case workspacePackConflict(String)

    var errorDescription: String? {
        switch self {
        case .corruptNativeStore(let message), .invalidLegacyStore(let message),
             .corruptBackup(let message), .invalidProject(let message),
             .workspacePackConflict(let message):
            message
        case .unsupportedSchema(let version):
            "Unsupported native store schema version: \(version)."
        case .projectNotFound(let id):
            "Project not found: \(id)."
        case .workspaceNotFound(let id):
            "Workspace not found: \(id)."
        case .backupUnavailable:
            "No last-known-good backup is available."
        }
    }
}

enum RecoveryChoice: Sendable {
    case restoreBackup
    case startFresh
    case quit
}

enum RecoveryResult: Equatable, Sendable {
    case restored(NativeStoreDocument)
    case startedFresh(preservedCorruptFile: URL?)
    case quit
}

struct MigrationResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case existingNativeStore
        case migratedElectronStore
        case emptyFirstLaunch
    }

    let document: NativeStoreDocument
    let outcome: Outcome
}

final class ProjectStore {
    private let paths: ProjectStorePaths
    private let fileSystem: any PersistenceFileSystem
    private let now: () -> String
    private let makeID: () -> String
    private let isDirectory: (String) -> Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let commandParser: CommandParser
    private let urlValidator: LocalURLValidator

    init(
        paths: ProjectStorePaths = .production(),
        fileSystem: any PersistenceFileSystem = LocalPersistenceFileSystem(),
        now: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) },
        makeID: @escaping () -> String = { UUID().uuidString },
        commandParser: CommandParser = CommandParser(),
        urlValidator: LocalURLValidator = LocalURLValidator(),
        isDirectory: @escaping (String) -> Bool = { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && directory.boolValue
        }
    ) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.now = now
        self.makeID = makeID
        self.commandParser = commandParser
        self.urlValidator = urlValidator
        self.isDirectory = isDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func loadOrMigrate() throws -> MigrationResult {
        if fileSystem.fileExists(at: paths.store) {
            return MigrationResult(document: try load(), outcome: .existingNativeStore)
        }

        if fileSystem.fileExists(at: paths.electronStore) {
            let legacy = try readElectronStore()
            let normalized = normalize(projects: legacy.projects, workspace: legacy.workspace)
            try validate(projects: normalized.projects, native: false)
            let document = NativeStoreDocument(
                schemaVersion: NativeStoreDocument.currentSchemaVersion,
                projects: normalized.projects,
                workspace: normalized.workspace,
                migration: MigrationMetadata(
                    source: "electron-projects-json",
                    sourcePath: paths.electronStore.path,
                    migratedAt: now()
                )
            )
            try save(document)
            return MigrationResult(document: document, outcome: .migratedElectronStore)
        }

        return MigrationResult(document: .empty, outcome: .emptyFirstLaunch)
    }

    func load() throws -> NativeStoreDocument {
        guard fileSystem.fileExists(at: paths.store) else {
            return .empty
        }
        let data: Data
        do {
            data = try fileSystem.readData(at: paths.store)
        } catch {
            throw PersistenceError.corruptNativeStore("Native store could not be read: \(error.localizedDescription)")
        }
        return try decodeNative(data)
    }

    func listProjects() throws -> [Project] {
        try load().projects
    }

    func project(id: String) throws -> Project? {
        try load().projects.first { $0.id == id }
    }

    @discardableResult
    func createProject(_ draft: ProjectDraft) throws -> Project {
        var document = try load()
        let timestamp = now()
        let project = try makeProject(from: draft, existing: nil, timestamp: timestamp)
        guard !document.projects.contains(where: { $0.id == project.id }) else {
            throw PersistenceError.invalidProject("Project ID already exists: \(project.id).")
        }
        document.projects.append(project)
        document.workspace = normalize(projects: document.projects, workspace: document.workspace).workspace
        try save(document)
        return project
    }

    @discardableResult
    func updateProject(id: String, _ draft: ProjectDraft) throws -> Project {
        var document = try load()
        guard let index = document.projects.firstIndex(where: { $0.id == id }) else {
            throw PersistenceError.projectNotFound(id)
        }
        let project = try makeProject(from: draft, existing: document.projects[index], timestamp: now())
        document.projects[index] = project
        document.workspace = normalize(projects: document.projects, workspace: document.workspace).workspace
        try save(document)
        return project
    }

    func deleteProject(id: String) throws {
        var document = try load()
        let originalCount = document.projects.count
        document.projects.removeAll { $0.id == id }
        guard document.projects.count != originalCount else {
            throw PersistenceError.projectNotFound(id)
        }
        document.workspace = normalize(projects: document.projects, workspace: document.workspace).workspace
        try save(document)
    }

    func workspace() throws -> WorkspaceState {
        try load().workspace
    }

    @discardableResult
    func writeWorkspace(_ workspace: WorkspaceState) throws -> WorkspaceState {
        var document = try load()
        let normalized = normalize(projects: document.projects, workspace: workspace).workspace
        document.workspace = normalized
        try save(document)
        return normalized
    }

    @discardableResult
    func setLastRunningProjectIDs(_ ids: [String]) throws -> WorkspaceState {
        var workspace = try self.workspace()
        workspace.lastRunningProjectIds = ids
        workspace.updatedAt = now()
        return try writeWorkspace(workspace)
    }

    @discardableResult
    func upsertWorkspaceProfile(
        id: String? = nil,
        name: String,
        projectIDs: [String],
        source: WorkspaceSource? = nil
    ) throws -> WorkspaceProfile {
        var document = try load()
        let timestamp = now()
        let requestedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileID = requestedID.flatMap { $0.isEmpty ? nil : $0 } ?? makeID()
        let existingIndex = document.workspace.savedWorkspaces.firstIndex { $0.id == profileID }
        let existing = existingIndex.map { document.workspace.savedWorkspaces[$0] }
        let profile = WorkspaceProfile(
            id: existing?.id ?? profileID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            projectIds: uniqueNonempty(projectIDs),
            createdAt: existing?.createdAt ?? timestamp,
            updatedAt: timestamp,
            lastStartedAt: existing?.lastStartedAt,
            source: source ?? existing?.source
        )
        if let existingIndex {
            document.workspace.savedWorkspaces[existingIndex] = profile
        } else {
            document.workspace.savedWorkspaces.append(profile)
        }
        document.workspace.updatedAt = timestamp
        try save(document)
        return profile
    }

    @discardableResult
    func markWorkspaceStarted(id: String) throws -> WorkspaceProfile {
        var document = try load()
        guard let index = document.workspace.savedWorkspaces.firstIndex(where: { $0.id == id }) else {
            throw PersistenceError.workspaceNotFound(id)
        }
        let timestamp = now()
        document.workspace.savedWorkspaces[index].lastStartedAt = timestamp
        document.workspace.savedWorkspaces[index].updatedAt = timestamp
        document.workspace.updatedAt = timestamp
        try save(document)
        return document.workspace.savedWorkspaces[index]
    }

    @discardableResult
    func importWorkspacePack(_ pack: ReviewedWorkspacePack) throws -> NativeStoreDocument {
        var document = try load()
        let timestamp = now()
        let packPath = canonicalPath(pack.packURL.path)
        let importedProjectIDs = pack.projects.map(\.id)
        guard Set(importedProjectIDs).count == importedProjectIDs.count else {
            throw PersistenceError.workspacePackConflict(
                "Workspace manifest project identities are not unique. Review the manifest again."
            )
        }

        // Resolve every manifest identity before materialising any project. A
        // dependency must always point at the saved LocalWrap ID, including on
        // the first import when that ID needs a collision-safe suffix.
        let projectMatches = try workspacePackProjectMatches(
            pack.projects,
            savedProjects: document.projects,
            packPath: packPath
        )
        var reservedProjectIDs = Set(document.projects.map(\.id))
        var savedIDByPackID: [String: String] = [:]
        for imported in pack.projects {
            if let index = projectMatches[imported.id] {
                savedIDByPackID[imported.id] = document.projects[index].id
            } else {
                let savedID = reserveWorkspacePackID(
                    preferred: imported.draft.id ?? imported.id,
                    reserved: &reservedProjectIDs
                )
                savedIDByPackID[imported.id] = savedID
            }
        }

        var didChange = false
        for imported in pack.projects {
            let index = projectMatches[imported.id]
            let existing = index.map { document.projects[$0] }
            var draft = imported.draft
            draft.id = savedIDByPackID[imported.id]
            draft.dependsOn = try imported.draft.dependsOn.map { dependencies in
                try dependencies.map { dependencyID in
                    guard let savedID = savedIDByPackID[dependencyID] else {
                        throw PersistenceError.workspacePackConflict(
                            "Workspace manifest dependency \"\(dependencyID)\" is unresolved. Review the manifest again."
                        )
                    }
                    return savedID
                }
            }
            draft.source = ProjectSource(
                type: "workspace-pack",
                packPath: packPath,
                packProjectId: imported.id
            )
            var project = try makeProject(from: draft, existing: existing, timestamp: timestamp)
            if let existing {
                project.createdAt = existing.createdAt
                project.updatedAt = existing.updatedAt
                if project != existing {
                    project.updatedAt = timestamp
                    didChange = true
                }
            } else {
                didChange = true
            }
            if let index {
                document.projects[index] = project
            } else {
                document.projects.append(project)
            }
        }

        let importedProfileIDs = pack.profiles.map(\.id)
        guard Set(importedProfileIDs).count == importedProfileIDs.count else {
            throw PersistenceError.workspacePackConflict(
                "Workspace manifest workspace identities are not unique. Review the manifest again."
            )
        }
        var reservedProfileIDs = Set(document.workspace.savedWorkspaces.map(\.id))
        for imported in pack.profiles {
            let projectIDs = try imported.projectIDs.map { packProjectID in
                guard let savedID = savedIDByPackID[packProjectID] else {
                    throw PersistenceError.workspacePackConflict(
                        "Workspace \"\(imported.name)\" references an unresolved project. Review the manifest again."
                    )
                }
                return savedID
            }
            guard !projectIDs.isEmpty else {
                throw PersistenceError.workspacePackConflict(
                    "Workspace \"\(imported.name)\" must contain at least one project."
                )
            }
            let provenanceMatches = document.workspace.savedWorkspaces.indices.filter { index in
                let source = document.workspace.savedWorkspaces[index].source
                return source?.type == "workspace-pack"
                    && source.map { canonicalPath($0.packPath) } == packPath
                    && source?.packWorkspaceId == imported.id
            }
            guard provenanceMatches.count <= 1 else {
                throw PersistenceError.workspacePackConflict(
                    "Multiple saved workspaces claim manifest identity \"\(imported.id)\". Resolve the duplicate before importing."
                )
            }
            let provenanceIndex = provenanceMatches.first
            let existing = provenanceIndex.map { document.workspace.savedWorkspaces[$0] }
            let profileID = existing?.id ?? reserveWorkspacePackID(
                preferred: imported.id,
                reserved: &reservedProfileIDs
            )
            var profile = WorkspaceProfile(
                id: profileID,
                name: imported.name,
                projectIds: projectIDs,
                createdAt: existing?.createdAt ?? timestamp,
                updatedAt: existing?.updatedAt ?? timestamp,
                lastStartedAt: existing?.lastStartedAt,
                source: WorkspaceSource(
                    type: "workspace-pack",
                    packPath: packPath,
                    packWorkspaceId: imported.id
                )
            )
            if let existing, profile != existing {
                profile.updatedAt = timestamp
                didChange = true
            } else if existing == nil {
                didChange = true
            }
            if let provenanceIndex {
                document.workspace.savedWorkspaces[provenanceIndex] = profile
            } else {
                document.workspace.savedWorkspaces.append(profile)
            }
        }
        if didChange {
            document.workspace.updatedAt = timestamp
            try save(document)
            return try load()
        }
        return document
    }

    private func workspacePackProjectMatches(
        _ importedProjects: [ReviewedWorkspacePackProject],
        savedProjects: [Project],
        packPath: String
    ) throws -> [String: Int] {
        var result: [String: Int] = [:]
        var claimedSavedIndices = Set<Int>()
        var unmatchedByDirectory: [String: [ReviewedWorkspacePackProject]] = [:]

        for imported in importedProjects {
            let provenanceMatches = savedProjects.indices.filter { index in
                let source = savedProjects[index].source
                return source?.type == "workspace-pack"
                    && source.map { canonicalPath($0.packPath) } == packPath
                    && source?.packProjectId == imported.id
            }
            guard provenanceMatches.count <= 1 else {
                throw PersistenceError.workspacePackConflict(
                    "Multiple saved projects claim manifest identity \"\(imported.id)\". Resolve the duplicate before importing."
                )
            }
            if let index = provenanceMatches.first {
                guard claimedSavedIndices.insert(index).inserted else {
                    throw PersistenceError.workspacePackConflict(
                        "A saved project matches more than one manifest project. Resolve its provenance before importing."
                    )
                }
                result[imported.id] = index
            } else {
                unmatchedByDirectory[canonicalPath(imported.draft.cwd), default: []].append(imported)
            }
        }

        for (directory, importedAtDirectory) in unmatchedByDirectory {
            let savedAtDirectory = savedProjects.indices.filter {
                !claimedSavedIndices.contains($0) && canonicalPath(savedProjects[$0].cwd) == directory
            }
            if savedAtDirectory.isEmpty {
                continue
            }
            guard importedAtDirectory.count == 1, savedAtDirectory.count == 1 else {
                let names = importedAtDirectory.map(\.name).sorted().joined(separator: ", ")
                throw PersistenceError.workspacePackConflict(
                    "Manifest projects \(names) cannot be matched safely to saved projects in \(directory). Resolve the duplicate folder mapping before importing."
                )
            }
            let imported = importedAtDirectory[0]
            let index = savedAtDirectory[0]
            claimedSavedIndices.insert(index)
            result[imported.id] = index
        }
        return result
    }

    private func reserveWorkspacePackID(preferred: String, reserved: inout Set<String>) -> String {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "workspace-item" : trimmed
        var candidate = base
        var suffix = 2
        while reserved.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        reserved.insert(candidate)
        return candidate
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func hasBackup() -> Bool {
        fileSystem.fileExists(at: paths.backup)
    }

    func recover(_ choice: RecoveryChoice) throws -> RecoveryResult {
        switch choice {
        case .restoreBackup:
            guard hasBackup() else {
                throw PersistenceError.backupUnavailable
            }
            let backupData: Data
            do {
                backupData = try fileSystem.readData(at: paths.backup)
            } catch {
                throw PersistenceError.corruptBackup("Backup could not be read: \(error.localizedDescription)")
            }
            let document: NativeStoreDocument
            do {
                document = try decodeNative(backupData)
            } catch {
                throw PersistenceError.corruptBackup("Backup is not a valid native store.")
            }
            try atomicReplace(backupData, at: paths.store)
            return .restored(document)
        case .startFresh:
            let preserved = try preserveCorruptStore()
            return .startedFresh(preservedCorruptFile: preserved)
        case .quit:
            return .quit
        }
    }

    private func readElectronStore() throws -> ElectronStoreDocument {
        let data: Data
        do {
            data = try fileSystem.readData(at: paths.electronStore)
        } catch {
            throw PersistenceError.invalidLegacyStore(
                "Electron projects file could not be read: \(error.localizedDescription)"
            )
        }
        do {
            let legacy = try decoder.decode(ElectronStoreDocument.self, from: data)
            try validate(projects: legacy.projects, native: false)
            return legacy
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.invalidLegacyStore("Electron projects file is structurally invalid.")
        }
    }

    private func decodeNative(_ data: Data) throws -> NativeStoreDocument {
        let document: NativeStoreDocument
        do {
            document = try decoder.decode(NativeStoreDocument.self, from: data)
        } catch {
            throw PersistenceError.corruptNativeStore("Native store is not valid schema-versioned JSON.")
        }
        guard document.schemaVersion == NativeStoreDocument.currentSchemaVersion else {
            throw PersistenceError.unsupportedSchema(document.schemaVersion)
        }
        do {
            try validate(projects: document.projects, native: true)
            try validate(workspace: document.workspace, projects: document.projects, native: true)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.corruptNativeStore("Native store is structurally invalid.")
        }
        let normalized = normalize(projects: document.projects, workspace: document.workspace)
        try validate(workspace: normalized.workspace, projects: normalized.projects, native: true)
        return NativeStoreDocument(
            schemaVersion: document.schemaVersion,
            projects: normalized.projects,
            workspace: normalized.workspace,
            migration: document.migration
        )
    }

    private func save(_ document: NativeStoreDocument) throws {
        try validate(projects: document.projects, native: true)
        let normalized = normalize(projects: document.projects, workspace: document.workspace)
        let payload = NativeStoreDocument(
            schemaVersion: NativeStoreDocument.currentSchemaVersion,
            projects: normalized.projects,
            workspace: normalized.workspace,
            migration: document.migration
        )
        let data = try encoder.encode(payload) + Data([0x0A])
        try fileSystem.createDirectory(at: paths.directory)
        try atomicReplace(data, at: paths.store)

        do {
            try atomicReplace(data, at: paths.backup)
        } catch {
            // The committed store remains authoritative if refreshing the backup fails.
        }
    }

    private func atomicReplace(_ data: Data, at destination: URL) throws {
        let temporary = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try fileSystem.writeData(data, to: temporary)
            try fileSystem.replaceItem(at: destination, with: temporary)
        } catch {
            if fileSystem.fileExists(at: temporary) {
                try? fileSystem.removeItem(at: temporary)
            }
            throw error
        }
    }

    private func preserveCorruptStore() throws -> URL? {
        guard fileSystem.fileExists(at: paths.store) else {
            return nil
        }
        let safeTimestamp = now().replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let preserved = paths.directory.appendingPathComponent(
            "store.json.corrupt-\(safeTimestamp)"
        )
        try fileSystem.moveItem(at: paths.store, to: preserved)
        return preserved
    }

    private func makeProject(
        from draft: ProjectDraft,
        existing: Project?,
        timestamp: String
    ) throws -> Project {
        let trimmedDirectory = draft.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = URL(fileURLWithPath: trimmedDirectory).lastPathComponent
        let trimmedName = draft.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(
            id: existing?.id ?? draft.id ?? makeID(),
            name: trimmedName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            cwd: trimmedDirectory,
            command: trimmedCommand,
            port: draft.port,
            url: draft.url.trimmingCharacters(in: .whitespacesAndNewlines),
            autostart: draft.autostart,
            openOnReady: draft.openOnReady,
            isSample: draft.isSample,
            createdAt: existing?.createdAt ?? timestamp,
            updatedAt: timestamp,
            dependsOn: uniqueNonempty(draft.dependsOn ?? existing?.dependsOn ?? []),
            healthCheck: draft.healthCheck,
            source: draft.source ?? existing?.source
        )
        guard isDirectory(project.cwd) else {
            throw PersistenceError.invalidProject("Working directory does not exist: \(project.cwd)")
        }
        do {
            try validate(projects: [project], native: true)
        } catch {
            throw PersistenceError.invalidProject(error.localizedDescription)
        }
        return project
    }

    private func validate(projects: [Project], native: Bool) throws {
        var ids = Set<String>()
        for project in projects {
            let required = [project.id, project.name, project.cwd, project.command, project.url]
            guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  (1_000...65_535).contains(project.port),
                  isISOTimestamp(project.createdAt),
                  isISOTimestamp(project.updatedAt),
                  (try? commandParser.parse(project.command)) != nil,
                  urlValidator.validate(project.url),
                  ids.insert(project.id).inserted else {
                let message = "A project has missing, duplicate, or invalid required fields."
                if native {
                    throw PersistenceError.corruptNativeStore(message)
                }
                throw PersistenceError.invalidLegacyStore(message)
            }
            if let source = project.source,
               source.type != "workspace-pack" || source.packPath.isEmpty || source.packProjectId.isEmpty {
                let message = "A project has invalid workspace-pack provenance."
                if native {
                    throw PersistenceError.corruptNativeStore(message)
                }
                throw PersistenceError.invalidLegacyStore(message)
            }
            if let healthCheck = project.healthCheck {
                let validPath = healthCheck.path.map { $0.hasPrefix("/") } ?? false
                let validURL = healthCheck.url.map(urlValidator.validate) ?? false
                if validPath == validURL {
                    let message = "A project has an invalid health check."
                    if native {
                        throw PersistenceError.corruptNativeStore(message)
                    }
                    throw PersistenceError.invalidLegacyStore(message)
                }
            }
        }
    }

    private func validate(
        workspace: WorkspaceState,
        projects: [Project],
        native: Bool
    ) throws {
        let validIDs = Set(projects.map(\.id))
        let runningAreValid = workspace.lastRunningProjectIds.allSatisfy(validIDs.contains)
        let profilesAreValid = workspace.savedWorkspaces.allSatisfy { profile in
            !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !profile.projectIds.isEmpty
                && profile.projectIds.allSatisfy(validIDs.contains)
                && profile.createdAt.map(isISOTimestamp) ?? true
                && profile.updatedAt.map(isISOTimestamp) ?? true
                && profile.lastStartedAt.map(isISOTimestamp) ?? true
                && isValid(source: profile.source)
        }
        let timestampIsValid = workspace.updatedAt.map(isISOTimestamp) ?? true
        guard runningAreValid, profilesAreValid, timestampIsValid else {
            let message = "Workspace state has invalid project references or metadata."
            if native {
                throw PersistenceError.corruptNativeStore(message)
            }
            throw PersistenceError.invalidLegacyStore(message)
        }
    }

    private func normalize(
        projects: [Project],
        workspace: WorkspaceState
    ) -> (projects: [Project], workspace: WorkspaceState) {
        let validIDs = Set(projects.map(\.id))
        let running = uniqueNonempty(workspace.lastRunningProjectIds).filter(validIDs.contains)
        let profiles = workspace.savedWorkspaces.compactMap { profile -> WorkspaceProfile? in
            let ids = uniqueNonempty(profile.projectIds).filter(validIDs.contains)
            guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !ids.isEmpty else {
                return nil
            }
            var normalized = profile
            normalized.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.name.isEmpty {
                normalized.name = "Workspace"
            }
            normalized.projectIds = ids
            return normalized
        }
        return (
            projects,
            WorkspaceState(
                lastRunningProjectIds: running,
                savedWorkspaces: profiles,
                updatedAt: workspace.updatedAt
            )
        )
    }

    private func uniqueNonempty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }
    }

    private func isISOTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil {
            return true
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private func isValid(source: WorkspaceSource?) -> Bool {
        guard let source else {
            return true
        }
        return source.type == "workspace-pack"
            && !source.packPath.isEmpty
            && !source.packWorkspaceId.isEmpty
    }
}
