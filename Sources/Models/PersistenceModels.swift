import Foundation

struct ProjectSource: Codable, Equatable, Sendable {
    let type: String
    let packPath: String
    let packProjectId: String
}

struct WorkspaceSource: Codable, Equatable, Sendable {
    let type: String
    let packPath: String
    let packWorkspaceId: String
}

struct HealthCheck: Codable, Equatable, Sendable {
    var path: String?
    var url: String?

    init(path: String) {
        self.path = path
        url = nil
    }

    init(url: String) {
        path = nil
        self.url = url
    }
}

struct Project: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var cwd: String
    var command: String
    var port: Int
    var url: String
    var autostart: Bool
    var openOnReady: Bool
    var isSample: Bool
    var createdAt: String
    var updatedAt: String
    var dependsOn: [String]?
    var healthCheck: HealthCheck?
    var source: ProjectSource?

    init(
        id: String,
        name: String,
        cwd: String,
        command: String,
        port: Int,
        url: String,
        autostart: Bool = false,
        openOnReady: Bool = false,
        isSample: Bool = false,
        createdAt: String,
        updatedAt: String,
        dependsOn: [String]? = nil,
        healthCheck: HealthCheck? = nil,
        source: ProjectSource? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.command = command
        self.port = port
        self.url = url
        self.autostart = autostart
        self.openOnReady = openOnReady
        self.isSample = isSample
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.dependsOn = dependsOn
        self.healthCheck = healthCheck
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, command, port, url, autostart, openOnReady, isSample
        case createdAt, updatedAt, dependsOn, healthCheck, source
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        cwd = try values.decode(String.self, forKey: .cwd)
        command = try values.decode(String.self, forKey: .command)
        port = try values.decode(Int.self, forKey: .port)
        url = try values.decode(String.self, forKey: .url)
        autostart = try values.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
        openOnReady = try values.decodeIfPresent(Bool.self, forKey: .openOnReady) ?? false
        isSample = try values.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
        createdAt = try values.decode(String.self, forKey: .createdAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        dependsOn = try values.decodeIfPresent([String].self, forKey: .dependsOn)
        healthCheck = try values.decodeIfPresent(HealthCheck.self, forKey: .healthCheck)
        source = try values.decodeIfPresent(ProjectSource.self, forKey: .source)
    }
}

struct WorkspaceProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var projectIds: [String]
    var createdAt: String?
    var updatedAt: String?
    var lastStartedAt: String?
    var source: WorkspaceSource?
}

struct WorkspaceState: Codable, Equatable, Sendable {
    var lastRunningProjectIds: [String]
    var savedWorkspaces: [WorkspaceProfile]
    var updatedAt: String?

    static let empty = WorkspaceState(
        lastRunningProjectIds: [],
        savedWorkspaces: [],
        updatedAt: nil
    )

    private enum CodingKeys: String, CodingKey {
        case lastRunningProjectIds, savedWorkspaces, updatedAt
    }

    init(
        lastRunningProjectIds: [String],
        savedWorkspaces: [WorkspaceProfile],
        updatedAt: String?
    ) {
        self.lastRunningProjectIds = lastRunningProjectIds
        self.savedWorkspaces = savedWorkspaces
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lastRunningProjectIds = try values.decodeIfPresent(
            [String].self,
            forKey: .lastRunningProjectIds
        ) ?? []
        savedWorkspaces = try values.decodeIfPresent(
            [WorkspaceProfile].self,
            forKey: .savedWorkspaces
        ) ?? []
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct MigrationMetadata: Codable, Equatable, Sendable {
    let source: String
    let sourcePath: String
    let migratedAt: String
}

struct NativeStoreDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projects: [Project]
    var workspace: WorkspaceState
    var migration: MigrationMetadata?

    static let empty = NativeStoreDocument(
        schemaVersion: currentSchemaVersion,
        projects: [],
        workspace: .empty,
        migration: nil
    )
}

struct ElectronStoreDocument: Codable, Equatable, Sendable {
    var projects: [Project]
    var workspace: WorkspaceState

    private enum CodingKeys: String, CodingKey {
        case projects, workspace
    }

    init(projects: [Project], workspace: WorkspaceState) {
        self.projects = projects
        self.workspace = workspace
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decode([Project].self, forKey: .projects)
        workspace = try values.decodeIfPresent(WorkspaceState.self, forKey: .workspace) ?? .empty
    }
}

struct ProjectDraft: Equatable, Sendable {
    var id: String?
    var name: String?
    var cwd: String
    var command: String
    var port: Int
    var url: String
    var autostart: Bool = false
    var openOnReady: Bool = false
    var isSample: Bool = false
    var dependsOn: [String]? = nil
    var healthCheck: HealthCheck? = nil
    var source: ProjectSource? = nil
}

extension ProjectDraft {
    init(project: Project) {
        self.init(
            id: project.id,
            name: project.name,
            cwd: project.cwd,
            command: project.command,
            port: project.port,
            url: project.url,
            autostart: project.autostart,
            openOnReady: project.openOnReady,
            isSample: project.isSample,
            dependsOn: project.dependsOn,
            healthCheck: project.healthCheck,
            source: project.source
        )
    }
}
