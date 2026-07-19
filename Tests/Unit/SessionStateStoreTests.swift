import Foundation
import XCTest
@testable import LocalWrapMac

@MainActor
final class SessionStateStoreTests: XCTestCase {
    func testStableProjectAndWorkspaceSelectionsRestoreOnlyWhenStillValid() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = makeProject(id: "web")
        let workspace = WorkspaceState(
            lastRunningProjectIds: [project.id],
            savedWorkspaces: [
                WorkspaceProfile(
                    id: "stack",
                    name: "Stack",
                    projectIds: [project.id],
                    createdAt: nil,
                    updatedAt: nil,
                    lastStartedAt: nil,
                    source: nil
                ),
            ],
            updatedAt: nil
        )

        try fixture.store.save(.project(project.id))
        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [project], workspace: workspace),
            .project(project.id)
        )
        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [], workspace: .empty),
            .welcome
        )

        try fixture.store.save(.workspace(.profile("stack")))
        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [project], workspace: workspace),
            .workspace(.profile("stack"))
        )
        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [project], workspace: .empty),
            .workspaces
        )

        try fixture.store.save(.workspace(.lastRunning))
        var staleLastRunning = workspace
        staleLastRunning.lastRunningProjectIds = [project.id, "removed-project"]
        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [project], workspace: staleLastRunning),
            .workspaces
        )
    }

    func testTransientSelectionDoesNotReplaceLastStableDestination() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try fixture.store.save(.projects)
        try fixture.store.save(.newProject)

        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [makeProject(id: "web")], workspace: .empty),
            .projects
        )
    }

    func testMissingCorruptAndUnsupportedSessionStateFailClosedToWelcome() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [], workspace: .empty),
            .welcome
        )
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{broken".utf8).write(to: fixture.fileURL)
        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [], workspace: .empty),
            .welcome
        )
        try JSONEncoder().encode(SessionStateDocument(
            schemaVersion: 99,
            selection: .projects
        )).write(to: fixture.fileURL)
        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [makeProject(id: "web")], workspace: .empty),
            .welcome
        )
    }

    func testNavigationRouterPersistsManualSelection() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = makeProject(id: "web")
        let router = NavigationRouter(store: fixture.store, projects: [project])

        router.show(.project(project.id))

        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [project], workspace: .empty),
            .project(project.id)
        )
    }

    func testNavigationRouterRevalidationFallsBackFromRemovedWorkspace() {
        let project = makeProject(id: "web")
        let workspace = WorkspaceState(
            lastRunningProjectIds: [project.id],
            savedWorkspaces: [
                WorkspaceProfile(
                    id: "stack",
                    name: "Stack",
                    projectIds: [project.id],
                    createdAt: nil,
                    updatedAt: nil,
                    lastStartedAt: nil,
                    source: nil
                ),
            ],
            updatedAt: nil
        )
        let router = NavigationRouter(
            selection: .workspace(.profile("stack")),
            projects: [project],
            workspace: workspace
        )

        router.revalidate(projects: [project], workspace: .empty)

        XCTAssertEqual(router.selection, .workspaces)
    }

    func testSaveUsesPrivateDirectoryAndFilePermissions() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try fixture.store.save(.projects)

        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.root.path)[.posixPermissions]
                as? NSNumber
        )
        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(directoryPermissions.uint16Value & 0o777, 0o700)
        XCTAssertEqual(filePermissions.uint16Value & 0o777, 0o600)
    }

    func testOversizedOrNonPrivateSessionStateFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try Data(repeating: 0x20, count: SessionStateDocument.maximumEncodedByteCount + 1)
            .write(to: fixture.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fixture.fileURL.path
        )

        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [makeProject(id: "web")], workspace: .empty),
            .welcome
        )

        try fixture.store.save(.projects)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: fixture.fileURL.path
        )
        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [makeProject(id: "web")], workspace: .empty),
            .welcome
        )
    }

    func testSymlinkedSessionStateFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let target = fixture.root.appendingPathComponent("target.json")
        let data = try JSONEncoder().encode(SessionStateDocument(
            schemaVersion: SessionStateDocument.currentSchemaVersion,
            selection: .projects
        ))
        try data.write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: fixture.fileURL, withDestinationURL: target)

        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [makeProject(id: "web")], workspace: .empty),
            .welcome
        )
    }

    func testInvalidSelectionIdentifiersAreRejectedOnSaveAndRestore() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try fixture.store.save(.project("unsafe\nidentifier"))) { error in
            XCTAssertEqual(error as? SessionStateError, .invalidSelectionIdentifier)
        }

        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let document = SessionStateDocument(
            schemaVersion: SessionStateDocument.currentSchemaVersion,
            selection: .project(String(repeating: "a", count: 129))
        )
        try JSONEncoder().encode(document).write(to: fixture.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fixture.fileURL.path
        )
        XCTAssertEqual(
            fixture.store.restoredSelection(projects: [makeProject(id: "web")], workspace: .empty),
            .welcome
        )
    }

    private func makeFixture() throws -> (root: URL, fileURL: URL, store: SessionStateStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWrapSession-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("session.json")
        return (root, fileURL, SessionStateStore(fileURL: fileURL))
    }

    private func makeProject(id: String) -> Project {
        Project(
            id: id,
            name: "Web",
            cwd: "/tmp",
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000",
            createdAt: "2026-07-18T00:00:00Z",
            updatedAt: "2026-07-18T00:00:00Z"
        )
    }
}
