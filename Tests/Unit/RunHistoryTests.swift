import Darwin
import Foundation
import XCTest
@testable import LocalWrapMac

final class RunHistoryTests: XCTestCase {
    private var root: URL!
    private var paths: RunHistoryPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunHistory-\(UUID().uuidString)", isDirectory: true)
        paths = RunHistoryPaths(
            directory: root,
            history: root.appendingPathComponent("run-history.json")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDiagnosticSanitizerRedactsSentinelsAndBoundsUnicodeSafely() {
        let sanitizer = DiagnosticSanitizer()
        let sentinels = [
            "Authorization: Bearer auth-sentinel",
            "password=password-sentinel",
            "TOKEN=token-sentinel",
            "https://localhost:3000/private?token=query-sentinel",
            "/Users/example/secret/project",
            #"C:\Users\example\secret"#,
            "safe\u{0000}control\u{202E}bidi",
        ]

        let sanitized = sentinels.map {
            sanitizer.sanitize($0, maximumUTF8ByteCount: 48)
        }.joined(separator: "|")

        for sentinel in [
            "auth-sentinel", "password-sentinel", "token-sentinel", "query-sentinel",
            "/Users/example", #"C:\Users"#, "\u{0000}", "\u{202E}",
        ] {
            XCTAssertFalse(sanitized.contains(sentinel), "Leaked sentinel: \(sentinel)")
        }
        XCTAssertTrue(sanitized.contains(DiagnosticSanitizer.redaction))
        XCTAssertTrue(sanitized.contains("[url]"))
        XCTAssertTrue(sanitized.contains("[path]"))
        XCTAssertTrue(
            sentinels.map { sanitizer.sanitize($0, maximumUTF8ByteCount: 48) }
                .allSatisfy { $0.utf8.count <= 48 }
        )
    }

    func testServiceHashesIdentifiersRejectsUnsafeTimestampsAndBoundsRunDetail() throws {
        let store = RunHistoryStore(paths: paths)
        let service = RunHistoryService(store: store)
        let rawProject = "/Users/example/project?token=project-sentinel"
        let rawRun = "npm run dev --password=run-sentinel"
        let transitions = (0..<50).map {
            RunHistoryTransitionInput(at: timestamp($0), state: .running)
        }
        let lifecycle = (0..<30).map {
            RunHistoryLifecycleInput(at: timestamp($0), event: .processStarted)
        }

        let document = try service.record(RunHistoryDraft(
            runID: rawRun,
            projectID: rawProject,
            startedAt: "token=timestamp-sentinel\u{202E}",
            endedAt: timestamp(99),
            finalState: .failed,
            exitCode: 2,
            transitions: transitions,
            lifecycleExcerpt: lifecycle
        ))

        let record = try XCTUnwrap(document.records.first)
        XCTAssertEqual(record.runReference.utf8.count, 64)
        XCTAssertEqual(record.projectReference.utf8.count, 64)
        XCTAssertEqual(record.startedAt, "unknown")
        XCTAssertEqual(record.transitions.count, RunHistoryRecord.maximumTransitions)
        XCTAssertEqual(record.lifecycleExcerpt.count, RunHistoryRecord.maximumLifecycleEntries)
        let persisted = try Data(contentsOf: paths.history)
        let text = String(decoding: persisted, as: UTF8.self)
        for sentinel in [rawProject, rawRun, "project-sentinel", "run-sentinel", "timestamp-sentinel"] {
            XCTAssertFalse(text.contains(sentinel), "Persisted raw sentinel: \(sentinel)")
        }
    }

    func testStoreEnforcesPerProjectAndGlobalHistoryBoundsAndClearAPIs() throws {
        let service = RunHistoryService(store: RunHistoryStore(paths: paths))
        for index in 0..<25 {
            _ = try service.record(draft(run: "shared-\(index)", project: "shared"))
        }
        XCTAssertEqual(try service.history().records.count, RunHistoryDocument.maximumRecordsPerProject)

        for index in 0..<120 {
            _ = try service.record(draft(run: "global-\(index)", project: "project-\(index)"))
        }
        XCTAssertEqual(try service.history().records.count, RunHistoryDocument.maximumRecordCount)

        _ = try service.clear(projectID: "project-119")
        XCTAssertFalse(
            try service.history().records.contains {
                $0.projectReference == DiagnosticSanitizer().opaqueReference(for: "project-119")
            }
        )
        try service.clearAll()
        XCTAssertEqual(try service.history(), .empty)
    }

    func testStoreCreatesPrivateObjectsAndRefusesSymlinkHistory() throws {
        let service = RunHistoryService(store: RunHistoryStore(paths: paths))
        _ = try service.record(draft(run: "run", project: "project"))

        var directoryMetadata = stat()
        var fileMetadata = stat()
        XCTAssertEqual(lstat(root.path, &directoryMetadata), 0)
        XCTAssertEqual(lstat(paths.history.path, &fileMetadata), 0)
        XCTAssertEqual(directoryMetadata.st_mode & mode_t(0o777), mode_t(0o700))
        XCTAssertEqual(fileMetadata.st_mode & mode_t(0o777), mode_t(0o600))
        XCTAssertEqual(fileMetadata.st_mode & S_IFMT, S_IFREG)

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let target = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        XCTAssertEqual(symlink(target.path, paths.history.path), 0)

        XCTAssertThrowsError(try RunHistoryStore(paths: paths).load())
    }

    func testSupportReportIsExactBoundedAndContainsOnlyCoarseReferences() throws {
        let service = RunHistoryService(store: RunHistoryStore(paths: paths))
        for index in 0..<100 {
            _ = try service.record(RunHistoryDraft(
                runID: "raw-run-\(index)-token=secret",
                projectID: "/Users/example/raw-project-\(index)",
                startedAt: timestamp(index),
                endedAt: timestamp(index + 1),
                finalState: .failed,
                exitCode: 1,
                transitions: (0..<RunHistoryRecord.maximumTransitions).map {
                    RunHistoryTransitionInput(at: timestamp($0), state: .running)
                },
                lifecycleExcerpt: (0..<RunHistoryRecord.maximumLifecycleEntries).map {
                    RunHistoryLifecycleInput(at: timestamp($0), event: .processExited)
                }
            ))
        }

        let report = SupportReportBuilder().build(
            history: try service.history(),
            generatedAt: timestamp(0)
        )

        XCTAssertEqual(report.previewText, report.copyText)
        XCTAssertEqual(report.copyText, report.exportText)
        XCTAssertEqual(report.exportData, Data(report.previewText.utf8))
        XCTAssertLessThanOrEqual(report.text.utf8.count, SupportReport.maximumUTF8ByteCount)
        XCTAssertTrue(report.text.contains("older run(s) omitted"))
        for sentinel in ["raw-run", "raw-project", "/Users/example", "token=secret"] {
            XCTAssertFalse(report.text.contains(sentinel), "Support report leaked \(sentinel)")
        }
        let first = try XCTUnwrap(try service.history().records.last)
        XCTAssertTrue(report.text.contains(String(first.runReference.prefix(12))))
        XCTAssertFalse(report.text.contains(first.runReference))
    }

    func testSupportReportSanitizesEvenUntrustedInMemoryHistory() {
        let unsafe = RunHistoryRecord(
            runReference: "raw-run-Authorization: Bearer report-auth-sentinel",
            projectReference: "/Users/example/report-path-sentinel",
            startedAt: "https://localhost:3000/?token=report-query-sentinel",
            endedAt: "password=report-password-sentinel\u{202E}",
            finalState: .failed,
            exitCode: 1,
            transitions: [],
            lifecycleExcerpt: []
        )

        let report = SupportReportBuilder().build(
            history: RunHistoryDocument(records: [unsafe]),
            generatedAt: "Authorization: Bearer generated-sentinel"
        )

        for sentinel in [
            "raw-run", "/Users/example", "report-auth-sentinel", "report-path-sentinel",
            "report-query-sentinel", "report-password-sentinel", "generated-sentinel", "\u{202E}",
        ] {
            XCTAssertFalse(report.text.contains(sentinel), "Support report leaked \(sentinel)")
        }
    }

    private func draft(run: String, project: String) -> RunHistoryDraft {
        RunHistoryDraft(
            runID: run,
            projectID: project,
            startedAt: timestamp(0),
            endedAt: timestamp(1),
            finalState: .stopped,
            exitCode: 0,
            transitions: [RunHistoryTransitionInput(at: timestamp(0), state: .starting)],
            lifecycleExcerpt: [RunHistoryLifecycleInput(at: timestamp(0), event: .launchRequested)]
        )
    }

    private func timestamp(_ index: Int) -> String {
        String(format: "2026-07-19T10:%02d:%02dZ", (index / 60) % 60, index % 60)
    }
}
