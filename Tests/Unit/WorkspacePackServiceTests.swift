import Foundation
import XCTest
@testable import LocalWrapMac

final class WorkspacePackServiceTests: XCTestCase {
    private var root: URL!
    private var web: URL!
    private var api: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePack-\(UUID().uuidString)", isDirectory: true)
        web = root.appendingPathComponent("apps/web", isDirectory: true)
        api = root.appendingPathComponent("services/api", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDiscoveryReviewAliasesAndRoundTripExport() throws {
        let packURL = root.appendingPathComponent(".localwrap/workspace.json")
        try FileManager.default.createDirectory(
            at: packURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let json = #"{"localwrap":1,"name":"Acme","projects":[{"id":"Web App","path":"apps/web","command":"npm run dev","port":"5173","dependsOn":["API Service"],"healthCheck":{"path":"/health"}},{"id":"API Service","path":"services/api","command":"node server.js","port":4000}],"workspaces":[{"name":"Full Stack","projects":["API Service","Web App"]}]}"#
        try Data(json.utf8).write(to: packURL)
        let service = WorkspacePackService()

        XCTAssertEqual(try service.discover(in: root), packURL)
        let reviewed = try service.review(rootURL: root)
        XCTAssertEqual(reviewed.projects.map(\.id), ["web-app", "api-service"])
        XCTAssertEqual(reviewed.projects[0].draft.dependsOn, ["api-service"])
        XCTAssertEqual(reviewed.profiles[0].projectIDs, ["api-service", "web-app"])

        let projects = reviewed.projects.enumerated().map { index, imported -> Project in
            Project(
                id: "saved-\(index)",
                name: imported.name,
                cwd: imported.draft.cwd,
                command: imported.draft.command,
                port: imported.draft.port,
                url: imported.draft.url,
                createdAt: "2026-07-10T20:00:00Z",
                updatedAt: "2026-07-10T20:00:00Z",
                dependsOn: index == 0 ? ["saved-1"] : nil,
                healthCheck: imported.draft.healthCheck,
                source: ProjectSource(
                    type: "workspace-pack",
                    packPath: packURL.path,
                    packProjectId: imported.id
                )
            )
        }
        let exported = try service.buildExport(
            rootURL: root,
            projects: projects,
            workspace: .empty,
            name: "Acme"
        )
        _ = try service.writeExport(exported, rootURL: root, overwrite: true)
        let reread = try service.review(rootURL: root)
        XCTAssertEqual(reread.projects.map(\.id), reviewed.projects.map(\.id))
        XCTAssertEqual(reread.projects[0].draft.dependsOn, ["api-service"])
    }

    func testRejectsAbsoluteEscapingSymlinkUnknownDependencyAndUnsafeCommand() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackOutside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let service = WorkspacePackService()

        XCTAssertThrowsError(try review(service, projects: [
            ["id": "bad", "path": outside.path, "command": "npm start"],
        ]))
        XCTAssertThrowsError(try review(service, projects: [
            ["id": "bad", "path": "escape", "command": "npm start"],
        ]))
        XCTAssertThrowsError(try review(service, projects: [
            ["id": "bad", "path": "apps/web", "command": "npm start", "dependsOn": ["missing"]],
        ]))
        XCTAssertThrowsError(try review(service, projects: [
            ["id": "bad", "path": "apps/web", "command": "bash run.sh"],
        ]))
    }

    func testTransactionalReimportPreservesIDsTimestampsAndProvenance() throws {
        let packURL = root.appendingPathComponent("localwrap.json")
        let payload: [String: Any] = [
            "localwrap": 1,
            "projects": [["id": "web", "path": "apps/web", "command": "npm start"]],
            "workspaces": [["id": "default", "name": "Default", "projects": ["web"]]],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: packURL)
        let service = WorkspacePackService()
        let reviewed = try service.review(rootURL: root)
        let paths = ProjectStorePaths(
            directory: root.appendingPathComponent("store", isDirectory: true),
            store: root.appendingPathComponent("store/store.json"),
            backup: root.appendingPathComponent("store/store.json.bak"),
            electronStore: root.appendingPathComponent("electron.json")
        )
        var ids = ["saved-project", "saved-workspace"].makeIterator()
        let store = ProjectStore(
            paths: paths,
            now: { "2026-07-10T20:00:00Z" },
            makeID: { ids.next() ?? UUID().uuidString }
        )

        let first = try service.importReviewed(reviewed, into: store)
        _ = try store.markWorkspaceStarted(id: first.workspace.savedWorkspaces[0].id)
        let second = try service.importReviewed(reviewed, into: store)

        XCTAssertEqual(second.projects.count, 1)
        XCTAssertEqual(second.projects[0].id, first.projects[0].id)
        XCTAssertEqual(second.projects[0].createdAt, first.projects[0].createdAt)
        XCTAssertEqual(second.projects[0].updatedAt, first.projects[0].updatedAt)
        XCTAssertEqual(second.projects[0].source?.packProjectId, "web")
        XCTAssertEqual(second.workspace.savedWorkspaces.count, 1)
        XCTAssertEqual(second.workspace.savedWorkspaces[0].lastStartedAt, "2026-07-10T20:00:00Z")
    }

    private func review(
        _ service: WorkspacePackService,
        projects: [[String: Any]]
    ) throws -> ReviewedWorkspacePack {
        let packURL = root.appendingPathComponent("localwrap.json")
        try JSONSerialization.data(withJSONObject: ["localwrap": 1, "projects": projects])
            .write(to: packURL)
        return try service.review(rootURL: root)
    }
}
