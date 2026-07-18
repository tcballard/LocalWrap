import Foundation
import XCTest
@testable import LocalWrapMac

final class WorkspaceManifestCommandTests: XCTestCase {
    func testIgnoresNormalApplicationLaunch() {
        let recorder = OutputRecorder()
        let command = makeCommand(recorder: recorder) { _, _ in
            XCTFail("Normal launches must not inspect a workspace manifest.")
            throw WorkspaceError.pack("Unexpected review")
        }

        XCTAssertNil(command.run(arguments: ["LocalWrapMac", "--ui-test-preview"]))
        XCTAssertTrue(recorder.output.isEmpty)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testUsageErrorsExitWithCodeTwoWithoutReviewing() {
        let recorder = OutputRecorder()
        let command = makeCommand(recorder: recorder) { _, _ in
            XCTFail("Invalid command usage must not inspect a workspace manifest.")
            throw WorkspaceError.pack("Unexpected review")
        }

        XCTAssertEqual(command.run(arguments: ["LocalWrap", "validate-manifest"]), 2)
        XCTAssertEqual(
            recorder.errors,
            ["Usage: LocalWrap validate-manifest <repository-or-manifest>"]
        )
    }

    func testRepositoryArgumentDiscoversAndReportsValidManifest() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = OutputRecorder()
        let command = WorkspaceManifestCommand(
            output: { recorder.output.append($0) },
            errorOutput: { recorder.errors.append($0) }
        )

        XCTAssertEqual(command.run(arguments: ["LocalWrap", "validate-manifest", root.path]), 0)
        XCTAssertEqual(recorder.output.first, "Valid LocalWrap workspace manifest")
        XCTAssertTrue(recorder.output.contains("Workspace: CLI Fixture"))
        XCTAssertTrue(recorder.output.contains("Projects: 1"))
        XCTAssertTrue(recorder.output.contains("Workspaces: 1"))
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testNestedManifestArgumentInfersRepositoryRoot() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent(".localwrap/workspace.json")
        let recorder = OutputRecorder()
        var reviewedRoot: URL?
        var reviewedManifest: URL?
        let command = makeCommand(recorder: recorder) { rootURL, packURL in
            reviewedRoot = rootURL
            reviewedManifest = packURL
            return try WorkspacePackService().review(rootURL: rootURL, packURL: packURL)
        }

        XCTAssertEqual(command.run(arguments: ["LocalWrap", "validate-manifest", manifest.path]), 0)
        XCTAssertEqual(reviewedRoot, root)
        XCTAssertEqual(reviewedManifest, manifest)
    }

    func testMissingRepositoryArgumentRemainsARepositoryLocation() {
        let recorder = OutputRecorder()
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingRepository-\(UUID().uuidString)", isDirectory: true)
        var didReview = false
        var reviewedRoot: URL?
        var reviewedManifest: URL?
        let command = makeCommand(recorder: recorder) { rootURL, packURL in
            didReview = true
            reviewedRoot = rootURL
            reviewedManifest = packURL
            throw WorkspaceError.pack("Missing repository")
        }

        XCTAssertEqual(command.run(arguments: ["LocalWrap", "validate-manifest", repository.path]), 1)
        XCTAssertTrue(didReview)
        XCTAssertEqual(reviewedRoot, repository)
        XCTAssertNil(reviewedManifest)
    }

    func testValidationBlockerExitsWithCodeOneAndDoesNotReportSuccess() throws {
        let root = try makeWorkspace(command: "bash unsafe.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = OutputRecorder()
        let command = WorkspaceManifestCommand(
            output: { recorder.output.append($0) },
            errorOutput: { recorder.errors.append($0) }
        )

        XCTAssertEqual(command.run(arguments: ["LocalWrap", "validate-manifest", root.path]), 1)
        XCTAssertTrue(recorder.output.isEmpty)
        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertTrue(recorder.errors[0].hasPrefix("Invalid LocalWrap workspace manifest:"))
    }

    func testMalformedAndNonObjectJSONExitWithCodeOneWithoutEchoingContents() throws {
        for raw in ["{private-value-not-json", #"["private-value"]"#] {
            let root = try makeWorkspace()
            defer { try? FileManager.default.removeItem(at: root) }
            let manifest = root.appendingPathComponent(".localwrap/workspace.json")
            try Data(raw.utf8).write(to: manifest)
            let recorder = OutputRecorder()
            let command = WorkspaceManifestCommand(
                output: { recorder.output.append($0) },
                errorOutput: { recorder.errors.append($0) }
            )

            XCTAssertEqual(command.run(arguments: ["LocalWrap", "validate-manifest", root.path]), 1)
            XCTAssertTrue(recorder.output.isEmpty)
            XCTAssertEqual(recorder.errors.count, 1)
            XCTAssertTrue(recorder.errors[0].hasPrefix("Invalid LocalWrap workspace manifest:"))
            XCTAssertFalse(recorder.errors[0].contains("private-value"))
        }
    }

    private func makeCommand(
        recorder: OutputRecorder,
        reviewer: @escaping WorkspaceManifestCommand.Reviewer
    ) -> WorkspaceManifestCommand {
        WorkspaceManifestCommand(
            reviewer: reviewer,
            output: { recorder.output.append($0) },
            errorOutput: { recorder.errors.append($0) }
        )
    }

    private func makeWorkspace(command: String = "npm run dev") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceManifestCommand-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("app", isDirectory: true)
        let manifest = root.appendingPathComponent(".localwrap/workspace.json")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "localwrap": 1,
            "name": "CLI Fixture",
            "projects": [[
                "id": "app",
                "path": "app",
                "command": command,
                "port": 3_000,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: manifest)
        return root
    }
}

private final class OutputRecorder {
    var output: [String] = []
    var errors: [String] = []
}
