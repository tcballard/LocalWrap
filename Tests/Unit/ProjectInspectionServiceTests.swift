import Foundation
import XCTest
@testable import LocalWrapMac

final class ProjectInspectionServiceTests: XCTestCase {
    func testDiscoversAndOrdersPackageScriptsWithFreePortSuggestion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Inspection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(
            #"{"name":"demo-app","scripts":{"test":"jest","start":"node .","dev":"vite"}}"#.utf8
        ).write(to: root.appendingPathComponent("package.json"))
        let ports = PortSuggestionService { $0 == 3_001 }
        let service = ProjectInspectionService(portSuggester: ports)

        let result = try service.inspect(directory: root, preferredPort: 3_000)

        XCTAssertEqual(result.name, "demo-app")
        XCTAssertEqual(result.scripts.map(\.name), ["dev", "start", "test"])
        XCTAssertEqual(result.recommendedCommand, "npm run dev")
        XCTAssertEqual(result.suggestedPort, 3_001)
        XCTAssertEqual(result.suggestedURL, "http://localhost:3001")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testMissingDirectoryReturnsActionableWarning() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing-\(UUID().uuidString)")
        let service = ProjectInspectionService(
            portSuggester: PortSuggestionService { _ in true }
        )

        let result = try service.inspect(directory: missing)

        XCTAssertEqual(result.warnings.map(\.code), ["cwd-missing"])
    }

    func testCopiesBundledSampleOnceAndWritesMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sample-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("demo".utf8).write(to: source.appendingPathComponent("README.md"))
        let service = SampleProjectService(now: { "2026-07-10T05:00:00.000Z" })

        XCTAssertTrue(try service.copyBundledSample(from: source, to: destination).copied)
        XCTAssertFalse(try service.copyBundledSample(from: source, to: destination).copied)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("README.md"), encoding: .utf8),
            "demo"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(SampleProjectService.markerFilename).path
            )
        )
    }
}
