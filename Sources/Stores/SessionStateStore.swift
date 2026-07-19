import Foundation

protocol SessionStateFileSystem {
    func fileExists(at url: URL) -> Bool
    func ensureDirectory(at url: URL, permissions: UInt16) throws
    func readPrivateData(at url: URL, maximumByteCount: Int) throws -> Data
    func writeFile(_ data: Data, to url: URL, permissions: UInt16) throws
    func replaceItemAtomically(at destination: URL, with source: URL) throws
    func syncDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
}

extension LocalRuntimeLedgerFileSystem: SessionStateFileSystem {}

enum SessionStateError: Error, Equatable {
    case invalidSelectionIdentifier
    case encodedStateTooLarge(actualByteCount: Int)
}

enum StableAppSelection: Codable, Equatable, Sendable {
    static let maximumIdentifierByteCount = 128

    case welcome
    case attention
    case workspaces
    case workspaceProfile(String)
    case lastRunning
    case allProjects
    case projects
    case project(String)

    init?(_ selection: AppSelection?) {
        guard let selection else { return nil }
        switch selection {
        case .welcome: self = .welcome
        case .attention: self = .attention
        case .workspaces: self = .workspaces
        case .workspace(.profile(let id)): self = .workspaceProfile(id)
        case .workspace(.lastRunning): self = .lastRunning
        case .workspace(.allProjects): self = .allProjects
        case .projects: self = .projects
        case .project(let id): self = .project(id)
        case .newProject: return nil
        }
    }

    var appSelection: AppSelection {
        switch self {
        case .welcome: .welcome
        case .attention: .attention
        case .workspaces: .workspaces
        case .workspaceProfile(let id): .workspace(.profile(id))
        case .lastRunning: .workspace(.lastRunning)
        case .allProjects: .workspace(.allProjects)
        case .projects: .projects
        case .project(let id): .project(id)
        }
    }

    var hasValidIdentifier: Bool {
        let identifier: String?
        switch self {
        case .workspaceProfile(let value), .project(let value):
            identifier = value
        case .welcome, .attention, .workspaces, .lastRunning, .allProjects, .projects:
            identifier = nil
        }
        guard let identifier else { return true }
        return !identifier.isEmpty
            && identifier.utf8.count <= Self.maximumIdentifierByteCount
            && identifier.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

struct SessionStateDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEncodedByteCount = 16 * 1_024
    let schemaVersion: Int
    let selection: StableAppSelection
}

struct SessionStateStore {
    private let fileURL: URL
    private let fileSystem: any SessionStateFileSystem
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileURL: URL = ProjectStorePaths.production().directory
            .appendingPathComponent("session.json"),
        fileSystem: any SessionStateFileSystem = LocalRuntimeLedgerFileSystem()
    ) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func restoredSelection(projects: [Project], workspace: WorkspaceState) -> AppSelection {
        guard fileSystem.fileExists(at: fileURL),
              let data = try? fileSystem.readPrivateData(
                at: fileURL,
                maximumByteCount: SessionStateDocument.maximumEncodedByteCount
              ),
              let document = try? decoder.decode(SessionStateDocument.self, from: data),
              document.schemaVersion == SessionStateDocument.currentSchemaVersion,
              document.selection.hasValidIdentifier else {
            return .welcome
        }
        return Self.validated(document.selection.appSelection, projects: projects, workspace: workspace)
    }

    func save(_ selection: AppSelection?) throws {
        guard let stable = StableAppSelection(selection) else { return }
        guard stable.hasValidIdentifier else {
            throw SessionStateError.invalidSelectionIdentifier
        }
        let document = SessionStateDocument(
            schemaVersion: SessionStateDocument.currentSchemaVersion,
            selection: stable
        )
        let data = try encoder.encode(document) + Data([0x0A])
        guard data.count <= SessionStateDocument.maximumEncodedByteCount else {
            throw SessionStateError.encodedStateTooLarge(actualByteCount: data.count)
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileSystem.ensureDirectory(at: directory, permissions: 0o700)
        let temporary = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try fileSystem.writeFile(data, to: temporary, permissions: 0o600)
            try fileSystem.replaceItemAtomically(at: fileURL, with: temporary)
            try fileSystem.syncDirectory(at: directory)
        } catch {
            if fileSystem.fileExists(at: temporary) {
                try? fileSystem.removeItem(at: temporary)
            }
            throw error
        }
    }

    static func validated(
        _ selection: AppSelection,
        projects: [Project],
        workspace: WorkspaceState
    ) -> AppSelection {
        switch selection {
        case .project(let id):
            return projects.contains { $0.id == id }
                ? selection
                : (projects.isEmpty ? .welcome : .projects)
        case .workspace(.profile(let id)):
            return workspace.savedWorkspaces.contains { $0.id == id }
                ? selection
                : (projects.isEmpty ? .welcome : .workspaces)
        case .workspace(.lastRunning):
            let knownProjectIDs = Set(projects.map(\.id))
            let isComplete = !workspace.lastRunningProjectIds.isEmpty
                && workspace.lastRunningProjectIds.allSatisfy(knownProjectIDs.contains)
            return isComplete ? selection : (projects.isEmpty ? .welcome : .workspaces)
        case .workspace(.allProjects):
            return projects.isEmpty ? .welcome : selection
        case .newProject:
            return projects.isEmpty ? .welcome : .projects
        case .welcome, .attention, .workspaces, .projects:
            return selection
        }
    }
}
