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
        let json = #"{"localwrap":1,"name":"Acme","projects":[{"id":"Web App","path":"apps/web","command":"npm run dev","port":5173,"dependsOn":["API Service"],"healthCheck":{"path":"/health"}},{"id":"API Service","path":"services/api","command":"node server.js","port":4000}],"workspaces":[{"name":"Full Stack","projects":["API Service","Web App"]}]}"#
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
        XCTAssertEqual(reread.projects.map(\.id).sorted(), reviewed.projects.map(\.id).sorted())
        XCTAssertEqual(
            reread.projects.first(where: { $0.id == "web-app" })?.draft.dependsOn,
            ["api-service"]
        )
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

    func testDiscoveryPrefersCanonicalNestedManifest() throws {
        let nested = root.appendingPathComponent(".localwrap/workspace.json")
        let rootManifest = root.appendingPathComponent("localwrap.json")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data(#"{"localwrap":1,"projects":[{"id":"web","path":"apps/web","command":"npm start"}]}"#.utf8)
        try payload.write(to: nested)
        try payload.write(to: rootManifest)

        XCTAssertEqual(try WorkspacePackService().discover(in: root), nested)
    }

    func testInspectionRejectsMalformedAndNonObjectJSON() throws {
        let service = WorkspacePackService()
        let packURL = root.appendingPathComponent("localwrap.json")

        for raw in ["{not-json", "[]"] {
            try Data(raw.utf8).write(to: packURL)

            let review = try service.inspect(rootURL: root)

            XCTAssertNil(review.pack)
            XCTAssertFalse(review.canImport)
            XCTAssertEqual(review.blockers.map(\.code), ["manifest-invalid"])
        }
    }

    func testInspectionRequiresExplicitIntegerVersionOne() throws {
        let service = WorkspacePackService()
        let packURL = root.appendingPathComponent("localwrap.json")
        let invalidVersions = [
            #"{"projects":[{"id":"web","path":"apps/web","command":"npm start"}]}"#,
            #"{"version":1,"projects":[{"id":"web","path":"apps/web","command":"npm start"}]}"#,
            #"{"localwrap":"1","projects":[{"id":"web","path":"apps/web","command":"npm start"}]}"#,
        ]

        for raw in invalidVersions {
            try Data(raw.utf8).write(to: packURL)

            let review = try service.inspect(rootURL: root)

            XCTAssertNil(review.pack)
            XCTAssertFalse(review.canImport)
            XCTAssertEqual(review.blockers.map(\.code), ["manifest-invalid"])
        }

        try Data(#"{"localwrap":2,"projects":[{"id":"web","path":"apps/web","command":"npm start"}]}"#.utf8)
            .write(to: packURL)
        let unsupported = try service.inspect(rootURL: root)
        XCTAssertNil(unsupported.pack)
        XCTAssertFalse(unsupported.canImport)
        XCTAssertTrue(unsupported.blockers.contains { $0.code == "unsupported-version" })
    }

    func testInspectionRejectsNonIntegerPortsInsteadOfDefaultingThem() throws {
        let service = WorkspacePackService()
        let packURL = root.appendingPathComponent("localwrap.json")
        let invalidPorts = [#""5173""#, #""not-a-port""#, "true"]

        for port in invalidPorts {
            let raw = #"{"localwrap":1,"projects":[{"id":"web","path":"apps/web","command":"npm start","port":\#(port)}]}"#
            try Data(raw.utf8).write(to: packURL)

            let review = try service.inspect(rootURL: root)

            XCTAssertNil(review.pack)
            XCTAssertFalse(review.canImport)
            XCTAssertEqual(review.blockers.map(\.code), ["manifest-invalid"])
        }
    }

    func testInspectionCollectsScopedBlockersWithoutProducingImportPayload() throws {
        let payload: [String: Any] = [
            "localwrap": 1,
            "environment": ["TOKEN": "must-not-be-read"],
            "projects": [
                [
                    "id": "web",
                    "path": "apps/web",
                    "command": "bash unsafe.sh",
                    "port": 3_000,
                    "dependsOn": ["api"],
                ],
                [
                    "id": "api",
                    "path": "../outside",
                    "command": "npm start",
                    "port": 3_000,
                    "url": "https://example.com:3000",
                    "dependsOn": ["web"],
                ],
            ],
            "workspaces": [["id": "stack", "projects": ["missing"]]],
        ]
        let packURL = root.appendingPathComponent("localwrap.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: packURL)

        let review = try WorkspacePackService().inspect(rootURL: root)
        let codes = Set(review.blockers.map(\.code))

        XCTAssertNil(review.pack)
        XCTAssertFalse(review.canImport)
        XCTAssertEqual(review.projects.count, 2)
        XCTAssertTrue(codes.isSuperset(of: [
            "sensitive-field-unsupported",
            "command-invalid",
            "project-path-escape",
            "url-invalid",
            "port-conflict",
            "dependency-cycle",
            "workspace-project-unknown",
        ]))
        XCTAssertThrowsError(try WorkspacePackService().review(rootURL: root))
    }

    func testInspectionPlansAddUpdateAndUnchangedUsingImportIdentity() throws {
        let packURL = root.appendingPathComponent("localwrap.json")
        try Data(#"{"localwrap":1,"name":"Stack","projects":[{"id":"web","path":"apps/web","name":"Web","command":"npm start","port":3000},{"id":"api","path":"services/api","name":"API","command":"node server.js","port":4000},{"id":"worker","path":".","name":"Worker","command":"npm run worker","port":5000}],"workspaces":[{"id":"default","name":"Default","projects":["web","api"]}]}"#.utf8)
            .write(to: packURL)
        let source: (String) -> ProjectSource = { id in
            ProjectSource(type: "workspace-pack", packPath: packURL.path, packProjectId: id)
        }
        let savedWeb = Project(
            id: "saved-web",
            name: "Web",
            cwd: web.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000",
            autostart: false,
            openOnReady: true,
            createdAt: "2026-07-10T20:00:00Z",
            updatedAt: "2026-07-10T20:00:00Z",
            source: source("web")
        )
        let savedAPI = Project(
            id: "saved-api",
            name: "Old API",
            cwd: api.path,
            command: "node server.js",
            port: 4_000,
            url: "http://localhost:4000",
            autostart: false,
            openOnReady: true,
            createdAt: "2026-07-10T20:00:00Z",
            updatedAt: "2026-07-10T20:00:00Z",
            source: source("api")
        )

        let review = try WorkspacePackService().inspect(
            rootURL: root,
            projects: [savedWeb, savedAPI],
            workspace: .empty
        )
        let projectChanges = Dictionary(uniqueKeysWithValues: review.changes
            .filter { $0.entity == .project }
            .map { ($0.entityID, $0.disposition) })

        XCTAssertEqual(projectChanges["web"], .unchanged)
        XCTAssertEqual(projectChanges["api"], .update)
        XCTAssertEqual(projectChanges["worker"], .add)
        XCTAssertTrue(review.canImport)
    }

    func testReviewedManifestMustBeReviewedAgainAfterRelevantSavedStateChanges() throws {
        let packURL = root.appendingPathComponent("localwrap.json")
        try Data(#"{"localwrap":1,"projects":[{"id":"web","path":"apps/web","command":"npm start","port":3000}]}"#.utf8)
            .write(to: packURL)
        let service = WorkspacePackService()
        let review = try service.inspect(rootURL: root)
        let paths = ProjectStorePaths(
            directory: root.appendingPathComponent("store", isDirectory: true),
            store: root.appendingPathComponent("store/store.json"),
            backup: root.appendingPathComponent("store/store.json.bak"),
            electronStore: root.appendingPathComponent("electron.json")
        )
        let store = ProjectStore(
            paths: paths,
            now: { "2026-07-10T20:00:00Z" },
            makeID: { "saved-web" }
        )
        _ = try store.createProject(ProjectDraft(
            id: "saved-web",
            name: "Existing Web",
            cwd: web.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000"
        ))

        XCTAssertThrowsError(try service.importReviewed(review, into: store)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed after review"))
        }
        XCTAssertEqual(try store.listProjects().count, 1)
        XCTAssertNil(try store.listProjects()[0].source)
    }

    func testInspectionBlocksAmbiguousSavedFolderMapping() throws {
        let packURL = root.appendingPathComponent("localwrap.json")
        try Data(#"{"localwrap":1,"projects":[{"id":"web","path":"apps/web","command":"npm start","port":3000}]}"#.utf8)
            .write(to: packURL)
        let timestamp = "2026-07-10T20:00:00Z"
        let saved = ["first", "second"].map { id in
            Project(
                id: id,
                name: id.capitalized,
                cwd: web.path,
                command: id == "first" ? "npm start" : "npm run dev",
                port: 3_000,
                url: "http://localhost:3000",
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }

        let review = try WorkspacePackService().inspect(
            rootURL: root,
            projects: saved,
            workspace: .empty
        )

        XCTAssertFalse(review.canImport)
        XCTAssertTrue(review.blockers.contains { $0.code == "saved-project-folder-ambiguous" })
    }

    func testEquivalentStateExportsByteIdenticallyAndRoundTrips() throws {
        let createdAt = "2026-07-10T20:00:00Z"
        let packURL = root.appendingPathComponent(".localwrap/workspace.json")
        let webProject = Project(
            id: "saved-web",
            name: "Web",
            cwd: web.path,
            command: "npm run dev",
            port: 5_173,
            url: "http://localhost:5173",
            createdAt: createdAt,
            updatedAt: createdAt,
            dependsOn: ["saved-api"],
            source: ProjectSource(type: "workspace-pack", packPath: packURL.path, packProjectId: "web")
        )
        let apiProject = Project(
            id: "saved-api",
            name: "API",
            cwd: api.path,
            command: "node server.js",
            port: 4_000,
            url: "http://localhost:4000",
            createdAt: createdAt,
            updatedAt: createdAt,
            source: ProjectSource(type: "workspace-pack", packPath: packURL.path, packProjectId: "api")
        )
        let profiles = [
            WorkspaceProfile(
                id: "saved-profile",
                name: "Full Stack",
                projectIds: ["saved-web", "saved-api"],
                createdAt: createdAt,
                updatedAt: createdAt,
                lastStartedAt: nil,
                source: WorkspaceSource(
                    type: "workspace-pack",
                    packPath: packURL.path,
                    packWorkspaceId: "default"
                )
            ),
        ]
        let workspace = WorkspaceState(lastRunningProjectIds: [], savedWorkspaces: profiles, updatedAt: createdAt)
        let service = WorkspacePackService()

        let first = try service.buildExport(
            rootURL: root,
            projects: [webProject, apiProject],
            workspace: workspace,
            name: "Stack"
        )
        let second = try service.buildExport(
            rootURL: root,
            projects: [apiProject, webProject],
            workspace: WorkspaceState(
                lastRunningProjectIds: [],
                savedWorkspaces: profiles.reversed(),
                updatedAt: createdAt
            ),
            name: "Stack"
        )

        XCTAssertEqual(try service.canonicalData(for: first.pack), try service.canonicalData(for: second.pack))
        _ = try service.writeExport(first, rootURL: root, overwrite: false)
        let reviewed = try service.review(rootURL: root)
        XCTAssertEqual(reviewed.projects.map(\.id), ["api", "web"])
        XCTAssertEqual(reviewed.projects.first(where: { $0.id == "web" })?.draft.dependsOn, ["api"])
        XCTAssertEqual(try Data(contentsOf: packURL), try service.canonicalData(for: first.pack))
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
