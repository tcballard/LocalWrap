import Foundation
import XCTest
@testable import LocalWrapMac

final class WorkspacePackExportValidationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePackExport-\(UUID().uuidString)", isDirectory: true)
        for folder in ["web", "api"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWriteExportRunsTheManifestValidatorBeforeCreatingAFile() throws {
        let invalidPacks = [
            pack(projects: [project(command: "bash run.sh")]),
            pack(projects: [project(url: "https://example.com:3000")]),
            pack(projects: [project(url: "http://user:secret@localhost:3000")]),
            pack(projects: [project(healthCheck: HealthCheck(path: "ready"))]),
            pack(projects: [
                project(id: "Web App", path: "web"),
                project(id: "web-app", path: "api", port: 4_000, url: "http://localhost:4000"),
            ]),
        ]
        let service = WorkspacePackService()
        let destination = root.appendingPathComponent(".localwrap/workspace.json")

        for invalidPack in invalidPacks {
            let result = WorkspacePackExportResult(pack: invalidPack, skippedProjects: [])

            XCTAssertThrowsError(try service.writeExport(result, rootURL: root, overwrite: false))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testWriteExportRejectsManifestDirectorySymlinkOutsideRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePackExportOutside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".localwrap", isDirectory: true),
            withDestinationURL: outside
        )
        let result = WorkspacePackExportResult(
            pack: pack(projects: [project()]),
            skippedProjects: []
        )

        XCTAssertThrowsError(
            try WorkspacePackService().writeExport(result, rootURL: root, overwrite: false)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.appendingPathComponent("workspace.json").path)
        )
    }

    private func pack(projects: [WorkspacePackProject]) -> WorkspacePackV1 {
        WorkspacePackV1(
            localwrap: 1,
            name: "Invalid",
            projects: projects,
            workspaces: [WorkspacePackProfile(
                id: "default",
                name: "Default",
                projects: projects.compactMap(\.id)
            )]
        )
    }

    private func project(
        id: String = "web",
        path: String = "web",
        command: String = "npm start",
        port: Int = 3_000,
        url: String = "http://localhost:3000",
        healthCheck: HealthCheck? = nil
    ) -> WorkspacePackProject {
        WorkspacePackProject(
            id: id,
            name: id,
            path: path,
            command: command,
            port: port,
            url: url,
            healthCheck: healthCheck
        )
    }
}
