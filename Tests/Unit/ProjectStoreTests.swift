import Foundation
import XCTest
@testable import LocalWrapMac

final class ProjectStoreTests: XCTestCase {
    private var root: URL!
    private var paths: ProjectStorePaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWrapMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = ProjectStorePaths(
            directory: root.appendingPathComponent("native", isDirectory: true),
            store: root.appendingPathComponent("native/store.json"),
            backup: root.appendingPathComponent("native/store.json.bak"),
            electronStore: root.appendingPathComponent("electron/projects.json")
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testEmptyFirstLaunchDoesNotCreateAStore() throws {
        let result = try makeStore().loadOrMigrate()

        XCTAssertEqual(result.outcome, .emptyFirstLaunch)
        XCTAssertEqual(result.document, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.store.path))
    }

    func testNativeStoreRoundTripUsesSchemaVersion() throws {
        let store = makeStore()
        let project = try store.createProject(draft(name: "Demo"))
        let document = try store.load()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.store)) as? [String: Any]
        )

        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(document.projects, [project])
        XCTAssertEqual(document.workspace, .empty)
    }

    func testPersistenceAcceptsSecureLocalURLPortMismatchButRejectsNonlocalURL() throws {
        let store = makeStore()
        var mismatch = draft(name: "Secure")
        mismatch.url = "https://localhost:4444"
        let saved = try store.createProject(mismatch)
        XCTAssertEqual(saved.port, 3_000)
        XCTAssertEqual(saved.url, "https://localhost:4444")

        var nonlocal = draft(name: "Remote")
        nonlocal.url = "https://example.com:3000"
        XCTAssertThrowsError(try store.createProject(nonlocal))
    }

    func testMigratesLegacyFixtureAndPreservesIDsTimestampsAndProvenance() throws {
        try installLegacyFixture()

        let result = try makeStore().loadOrMigrate()

        XCTAssertEqual(result.outcome, .migratedElectronStore)
        XCTAssertEqual(result.document.projects.map(\.id), ["project-api", "project-web"])
        XCTAssertEqual(result.document.projects[0].createdAt, "2026-06-05T00:00:00.000Z")
        XCTAssertEqual(result.document.projects[1].updatedAt, "2026-06-06T00:00:01.000Z")
        XCTAssertEqual(result.document.projects[1].dependsOn, ["project-api"])
        XCTAssertEqual(
            result.document.projects[0].healthCheck,
            HealthCheck(url: "http://127.0.0.1:4000/ready")
        )
        XCTAssertEqual(result.document.projects[1].healthCheck, HealthCheck(path: "/health"))
        XCTAssertEqual(result.document.projects[1].source?.packProjectId, "web")
        XCTAssertEqual(
            result.document.workspace.savedWorkspaces[0].source?.packWorkspaceId,
            "default"
        )
        XCTAssertEqual(result.document.migration?.sourcePath, paths.electronStore.path)
        XCTAssertEqual(result.document.migration?.migratedAt, timestamp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.electronStore.path))
    }

    func testMigrationIsIdempotentWhenElectronSourceChanges() throws {
        try installLegacyFixture()
        let store = makeStore()
        let first = try store.loadOrMigrate()
        try Data("{not-json".utf8).write(to: paths.electronStore)

        let second = try store.loadOrMigrate()

        XCTAssertEqual(second.outcome, .existingNativeStore)
        XCTAssertEqual(second.document, first.document)
        XCTAssertEqual(try String(contentsOf: paths.electronStore, encoding: .utf8), "{not-json")
    }

    func testAtomicReplacementFailureLeavesPreviousStoreIntact() throws {
        let initialStore = makeStore()
        _ = try initialStore.createProject(draft(name: "Survivor"))
        let original = try Data(contentsOf: paths.store)
        let failingFileSystem = FailingReplacementFileSystem(failingDestination: paths.store)
        let store = makeStore(fileSystem: failingFileSystem)

        XCTAssertThrowsError(try store.createProject(draft(name: "Never committed")))
        XCTAssertEqual(try Data(contentsOf: paths.store), original)
        XCTAssertEqual(try initialStore.listProjects().map(\.name), ["Survivor"])
    }

    func testBackupCreationAndRestoration() throws {
        let store = makeStore()
        _ = try store.createProject(draft(name: "Recoverable"))
        XCTAssertTrue(store.hasBackup())
        try Data("{broken".utf8).write(to: paths.store)

        let result = try store.recover(.restoreBackup)

        guard case .restored(let document) = result else {
            return XCTFail("Expected a restored document")
        }
        XCTAssertEqual(document.projects.map(\.name), ["Recoverable"])
        XCTAssertEqual(try store.listProjects().map(\.name), ["Recoverable"])
    }

    func testCorruptNativeFileIsPreservedWhenStartingFresh() throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: paths.store)
        let store = makeStore()

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .corruptNativeStore("Native store is not valid schema-versioned JSON.")
            )
        }
        let result = try store.recover(.startFresh)

        guard case .startedFresh(let preserved) = result else {
            return XCTFail("Expected start-fresh recovery")
        }
        let preservedURL = try XCTUnwrap(preserved)
        XCTAssertEqual(try Data(contentsOf: preservedURL), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.store.path))
        XCTAssertEqual(try store.load(), .empty)
    }

    func testStructurallyInvalidNativeStoreIsNotOverwrittenOrReplacedByMigration() throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.electronStore.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let invalidNative = Data(#"{"schemaVersion":1,"projects":{},"workspace":{}}"#.utf8)
        try invalidNative.write(to: paths.store)
        try installLegacyFixture(replacingExisting: true)

        XCTAssertThrowsError(try makeStore().loadOrMigrate())
        XCTAssertEqual(try Data(contentsOf: paths.store), invalidNative)
    }

    func testInvalidLegacyDataDoesNotCreateNativeStoreOrAlterSource() throws {
        try FileManager.default.createDirectory(
            at: paths.electronStore.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let invalid = Data(#"{"projects":{"wrong":true}}"#.utf8)
        try invalid.write(to: paths.electronStore)

        XCTAssertThrowsError(try makeStore().loadOrMigrate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.store.path))
        XCTAssertEqual(try Data(contentsOf: paths.electronStore), invalid)
    }

    func testCRUDAndWorkspaceReferencesAreNormalized() throws {
        let store = makeStore()
        let first = try store.createProject(draft(name: "First", id: "first"))
        let second = try store.createProject(draft(name: "Second", id: "second"))
        let updated = try store.updateProject(
            id: second.id,
            draft(name: "Renamed", id: "ignored", command: "npm run preview")
        )
        XCTAssertEqual(updated.id, "second")
        XCTAssertEqual(updated.createdAt, second.createdAt)

        let workspace = WorkspaceState(
            lastRunningProjectIds: [first.id, "missing", first.id],
            savedWorkspaces: [
                WorkspaceProfile(
                    id: "stack",
                    name: " Stack ",
                    projectIds: [first.id, updated.id, "missing", first.id],
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    lastStartedAt: nil,
                    source: nil
                ),
            ],
            updatedAt: timestamp
        )
        let normalized = try store.writeWorkspace(workspace)
        XCTAssertEqual(normalized.lastRunningProjectIds, [first.id])
        XCTAssertEqual(normalized.savedWorkspaces[0].projectIds, [first.id, updated.id])
        XCTAssertEqual(normalized.savedWorkspaces[0].name, "Stack")

        try store.deleteProject(id: first.id)
        XCTAssertEqual(try store.workspace().lastRunningProjectIds, [])
        XCTAssertEqual(try store.workspace().savedWorkspaces[0].projectIds, [updated.id])
        XCTAssertEqual(try store.listProjects().map(\.name), ["Renamed"])
    }

    func testWorkspacePackProvenanceRoundTrips() throws {
        let store = makeStore()
        let source = ProjectSource(
            type: "workspace-pack",
            packPath: "/repo/.localwrap/workspace.json",
            packProjectId: "web"
        )
        let project = try store.createProject(
            draft(name: "Web", id: "web", source: source, dependsOn: ["api"])
        )
        let profileSource = WorkspaceSource(
            type: "workspace-pack",
            packPath: source.packPath,
            packWorkspaceId: "default"
        )
        _ = try store.writeWorkspace(
            WorkspaceState(
                lastRunningProjectIds: [],
                savedWorkspaces: [
                    WorkspaceProfile(
                        id: "workspace",
                        name: "Default",
                        projectIds: [project.id],
                        createdAt: timestamp,
                        updatedAt: timestamp,
                        lastStartedAt: nil,
                        source: profileSource
                    ),
                ],
                updatedAt: timestamp
            )
        )

        XCTAssertEqual(try store.load().projects[0].source, source)
        XCTAssertEqual(try store.workspace().savedWorkspaces[0].source, profileSource)
    }

    func testQuitRecoveryDoesNotTouchCorruptStore() throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        let corrupt = Data("bad".utf8)
        try corrupt.write(to: paths.store)

        XCTAssertEqual(try makeStore().recover(.quit), .quit)
        XCTAssertEqual(try Data(contentsOf: paths.store), corrupt)
    }

    func testProductionPathsKeepDebugNativeDataSeparateFromElectron() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let production = ProjectStorePaths.production(homeDirectory: home)

        #if DEBUG
        XCTAssertTrue(production.directory.path.hasSuffix("Application Support/LocalWrapNative-Debug"))
        #else
        XCTAssertTrue(production.directory.path.hasSuffix("Application Support/LocalWrapNative"))
        #endif
        XCTAssertTrue(production.electronStore.path.hasSuffix("Application Support/localwrap/projects.json"))
        XCTAssertNotEqual(production.store.deletingLastPathComponent(), production.electronStore.deletingLastPathComponent())
    }

    private var timestamp: String { "2026-07-10T05:00:00.000Z" }

    private func makeStore(
        fileSystem: any PersistenceFileSystem = LocalPersistenceFileSystem()
    ) -> ProjectStore {
        ProjectStore(
            paths: paths,
            fileSystem: fileSystem,
            now: { self.timestamp },
            makeID: { "generated-id" }
        )
    }

    private func draft(
        name: String,
        id: String? = nil,
        command: String = "npm start",
        source: ProjectSource? = nil,
        dependsOn: [String]? = nil
    ) -> ProjectDraft {
        let directory = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ProjectDraft(
            id: id,
            name: name,
            cwd: directory.path,
            command: command,
            port: 3_000,
            url: "http://localhost:3000",
            dependsOn: dependsOn,
            source: source
        )
    }

    private func installLegacyFixture(replacingExisting: Bool = false) throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/electron-projects.json")
        try FileManager.default.createDirectory(
            at: paths.electronStore.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if replacingExisting, FileManager.default.fileExists(atPath: paths.electronStore.path) {
            try FileManager.default.removeItem(at: paths.electronStore)
        }
        try FileManager.default.copyItem(at: fixture, to: paths.electronStore)
    }
}

private final class FailingReplacementFileSystem: PersistenceFileSystem {
    private let base = LocalPersistenceFileSystem()
    private let failingDestination: URL

    init(failingDestination: URL) {
        self.failingDestination = failingDestination
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }
    func writeData(_ data: Data, to url: URL) throws { try base.writeData(data, to: url) }
    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }
    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }

    func replaceItem(at destination: URL, with source: URL) throws {
        if destination == failingDestination {
            throw CocoaError(.fileWriteUnknown)
        }
        try base.replaceItem(at: destination, with: source)
    }
}
