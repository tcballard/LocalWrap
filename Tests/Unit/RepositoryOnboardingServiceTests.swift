import Foundation
import XCTest
@testable import LocalWrapMac

final class RepositoryOnboardingServiceTests: XCTestCase {
    func testSingleRunnableScriptProducesReviewedStoppedProposal() throws {
        let root = try repository(packageJSON: #"{"name":"demo","scripts":{"dev":"vite","test":"vitest"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RepositoryOnboardingService(inspector: ProjectInspectionService(
            portSuggester: PortSuggestionService { $0 == 3_001 }
        ))

        let proposal = try service.propose(directory: root)

        XCTAssertEqual(proposal.draft.name, "demo")
        XCTAssertEqual(proposal.draft.command, "npm run dev")
        XCTAssertEqual(proposal.draft.port, 3_001)
        XCTAssertEqual(proposal.draft.url, "http://localhost:3001")
        XCTAssertFalse(proposal.draft.autostart)
        XCTAssertFalse(proposal.draft.openOnReady)
        XCTAssertEqual(proposal.nameSource, .packageJSON)
        XCTAssertEqual(proposal.commandSource, .packageScript)
        XCTAssertFalse(proposal.warnings.contains { $0.code == "command-choice-required" })
    }

    func testAmbiguousScriptsRequireExplicitReviewWithoutExecuting() throws {
        let root = try repository(packageJSON: #"{"scripts":{"dev":"vite","start":"node ."}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RepositoryOnboardingService(inspector: ProjectInspectionService(
            portSuggester: PortSuggestionService { _ in true }
        ))

        let proposal = try service.propose(directory: root)

        XCTAssertEqual(proposal.draft.command, "")
        XCTAssertEqual(proposal.commandSource, .reviewRequired)
        XCTAssertEqual(proposal.scripts.map(\.name), ["dev", "start"])
        XCTAssertTrue(proposal.warnings.contains { $0.code == "command-choice-required" })
        var selected = proposal.draft
        selected.command = "npm run dev"
        XCTAssertEqual(
            proposal.source(for: .command, currentDraft: selected),
            "Detected from package.json scripts"
        )
    }

    func testSelectedSymlinkIsCanonicalizedBeforeInspection() throws {
        let root = try repository(packageJSON: #"{"scripts":{"start":"node ."}}"#)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let link = root.deletingLastPathComponent().appendingPathComponent("repository-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let service = RepositoryOnboardingService(inspector: ProjectInspectionService(
            portSuggester: PortSuggestionService { _ in true }
        ))

        let proposal = try service.propose(directory: link)

        XCTAssertEqual(proposal.rootURL.path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(proposal.draft.cwd, root.resolvingSymlinksInPath().path)
    }

    func testProvenanceChangesWhenDetectedValueIsEdited() throws {
        let root = try repository(packageJSON: #"{"name":"demo","scripts":{"dev":"vite"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try RepositoryOnboardingService(
            inspector: ProjectInspectionService(
                portSuggester: PortSuggestionService { _ in true }
            )
        ).propose(directory: root)
        var edited = proposal.draft
        edited.name = "Renamed"

        XCTAssertEqual(proposal.source(for: .name, currentDraft: proposal.draft), "Detected from package.json")
        XCTAssertEqual(proposal.source(for: .name, currentDraft: edited), "Edited by you")
        XCTAssertEqual(proposal.source(for: .command, currentDraft: edited), "Detected from package.json scripts")
    }

    func testWorkspaceManifestWinsOverPackageInspectionAndOnlyProducesReview() throws {
        let root = try repository(packageJSON: #"{"name":"package-name","scripts":{"dev":"vite"}}"#)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let manifestDirectory = root.appendingPathComponent(".localwrap", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try Data(#"{"localwrap":1,"name":"Manifest Stack","projects":[{"id":"app","path":".","command":"npm start","port":3000}]}"#.utf8)
            .write(to: manifestDirectory.appendingPathComponent("workspace.json"))
        let service = RepositoryOnboardingService(inspector: ProjectInspectionService(
            portSuggester: PortSuggestionService { _ in true }
        ))

        let proposal = try service.openProposal(directory: root, projects: [], workspace: .empty)

        guard case .workspace(let review) = proposal else {
            return XCTFail("Expected the repository manifest review to take precedence.")
        }
        XCTAssertEqual(review.name, "Manifest Stack")
        XCTAssertTrue(review.canImport)
        XCTAssertEqual(review.projects.map(\.command), ["npm start"])
    }

    func testRepositoryWithoutManifestFallsThroughToProjectProposal() throws {
        let root = try repository(packageJSON: #"{"name":"demo","scripts":{"dev":"vite"}}"#)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let proposal = try RepositoryOnboardingService().openProposal(
            directory: root,
            projects: [],
            workspace: .empty
        )

        guard case .project(let project) = proposal else {
            return XCTFail("Expected ordinary repository inspection.")
        }
        XCTAssertEqual(project.draft.name, "demo")
        XCTAssertEqual(project.draft.command, "npm run dev")
    }

    private func repository(packageJSON: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryOnboarding-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(packageJSON.utf8).write(to: root.appendingPathComponent("package.json"))
        return root
    }
}
