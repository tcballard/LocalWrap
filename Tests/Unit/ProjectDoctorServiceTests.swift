import Foundation
import XCTest
@testable import LocalWrapMac

final class ProjectDoctorServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Doctor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHealthyConfigurationReturnsSevenOrderedPassingConfigurationChecks() throws {
        try writePackage(scripts: ["dev": "vite"])
        let diagnosis = doctor().diagnose(draft())

        XCTAssertEqual(diagnosis.status, .idle)
        XCTAssertEqual(diagnosis.checks.map(\.id), DoctorCheckID.allCases)
        XCTAssertEqual(diagnosis.check(.directory).status, .pass)
        XCTAssertEqual(diagnosis.check(.command).status, .pass)
        XCTAssertEqual(diagnosis.check(.dependencies).status, .pass)
        XCTAssertEqual(diagnosis.check(.port).status, .pass)
        XCTAssertEqual(diagnosis.check(.url).status, .pass)
        XCTAssertEqual(diagnosis.check(.process).status, .pending)
        XCTAssertEqual(diagnosis.check(.readiness).status, .pending)
    }

    func testEveryBlockingFieldFailureIsReportedInlineAndBlocksStart() throws {
        try writePackage(scripts: ["dev": "vite"])
        let cases: [(ProjectField, (inout ProjectDraft) -> Void)] = [
            (.name, { $0.name = "" }),
            (.cwd, { $0.cwd = "/path/that/does/not/exist" }),
            (.command, { $0.command = "" }),
            (.command, { $0.command = "npm start; open https://example.com" }),
            (.port, { $0.port = 999 }),
            (.url, { $0.url = "https://example.com:3000" }),
        ]

        for (field, mutate) in cases {
            var candidate = draft()
            mutate(&candidate)
            let diagnosis = doctor().diagnose(candidate)
            XCTAssertEqual(diagnosis.status, .failed, "Expected \(field.rawValue) to block")
            XCTAssertNotNil(diagnosis.validation.errors.first { $0.field == field })
        }
    }

    func testPackageInspectionWarningsDoNotBlockStart() throws {
        let missing = doctor().diagnose(draft())
        XCTAssertEqual(missing.status, .attention)
        XCTAssertEqual(missing.check(.directory).status, .warn)

        try Data("{broken".utf8).write(to: root.appendingPathComponent("package.json"))
        let invalid = doctor().diagnose(draft())
        XCTAssertEqual(invalid.check(.directory).status, .warn)

        try writePackage(scripts: [:])
        let noScripts = doctor().diagnose(draft())
        XCTAssertEqual(noScripts.check(.command).status, .warn)
    }

    func testDependencyGuidanceUsesEverySupportedLockfile() throws {
        let cases = [
            ("pnpm-lock.yaml", "pnpm install"),
            ("yarn.lock", "yarn install"),
            ("bun.lock", "bun install"),
            ("bun.lockb", "bun install"),
            ("package-lock.json", "npm install"),
        ]
        for (lockfile, command) in cases {
            let directory = root.appendingPathComponent(lockfile, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writePackage(
                scripts: ["dev": "vite"],
                dependencies: ["vite": "latest"],
                in: directory
            )
            try Data().write(to: directory.appendingPathComponent(lockfile))
            var candidate = draft()
            candidate.cwd = directory.path

            let check = doctor().diagnose(candidate).check(.dependencies)
            XCTAssertEqual(check.status, .warn)
            XCTAssertTrue(check.message.contains(command), check.message)
        }
    }

    func testBusyPortAndURLMismatchOfferSafeFixes() throws {
        try writePackage(scripts: ["dev": "vite"])
        let service = doctor(availablePorts: [3_001])
        var candidate = draft()
        candidate.url = "https://localhost:4444"
        let diagnosis = service.diagnose(candidate)

        XCTAssertEqual(diagnosis.check(.port).actions, [.findFreePort])
        XCTAssertEqual(diagnosis.check(.url).actions, [.syncURL])
        XCTAssertEqual(try service.actionPatch(for: candidate, action: .syncURL).url, "http://localhost:3000")
        let free = try service.actionPatch(for: candidate, action: .findFreePort)
        XCTAssertEqual(free.port, 3_001)
        XCTAssertEqual(free.url, "https://localhost:4444")

        candidate.url = "http://localhost:3000"
        let generated = try service.actionPatch(for: candidate, action: .findFreePort)
        XCTAssertEqual(generated.url, "http://localhost:3001")
    }

    func testUnknownActionIsRejected() throws {
        XCTAssertThrowsError(try doctor().actionPatch(for: draft(), actionID: "install-dependencies")) {
            XCTAssertEqual($0 as? DoctorError, .unknownAction("install-dependencies"))
        }
    }

    func testTimelineAndReportBoundsAreElectronCompatible() throws {
        var diagnosis = ProjectDiagnosis.notChecked(now: "0")
        for index in 0..<30 {
            diagnosis.addTimeline("event-\(index)", status: .info, at: "\(index)")
        }
        var runtime = RuntimeSnapshot(diagnosis: diagnosis)
        for index in 0..<30 { runtime.appendLog("log-\(index)") }
        let report = DoctorReportBuilder().build(project: draft(), runtime: runtime)

        XCTAssertEqual(diagnosis.timeline.count, 25)
        XCTAssertEqual(diagnosis.timeline.first?.message, "event-5")
        XCTAssertFalse(report.contains("log-9\n"))
        XCTAssertTrue(report.contains("log-10"))
        XCTAssertTrue(report.contains("log-29"))
    }

    private func draft() -> ProjectDraft {
        ProjectDraft(
            name: "Demo",
            cwd: root.path,
            command: "npm run dev",
            port: 3_000,
            url: "http://localhost:3000"
        )
    }

    private func doctor(availablePorts: Set<Int> = [3_000]) -> ProjectDoctorService {
        ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: availablePorts.contains),
            now: { "2026-07-10T12:00:00Z" }
        )
    }

    private func writePackage(
        scripts: [String: String],
        dependencies: [String: String] = [:],
        in directory: URL? = nil
    ) throws {
        let object: [String: Any] = ["scripts": scripts, "dependencies": dependencies]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: (directory ?? root).appendingPathComponent("package.json"))
    }
}
