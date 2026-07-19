import Foundation
import XCTest
@testable import LocalWrapMac

final class DoctorReportBuilderTests: XCTestCase {
    func testReportIsBoundedStructuredAndOmitsSensitiveSourceText() {
        let sentinel = "SENTINEL-SECRET-9f3d"
        let draft = ProjectDraft(
            id: "project-\(sentinel)",
            name: "Customer \(sentinel)",
            cwd: "/Users/example/private/\(sentinel)",
            command: "npm start --token=\(sentinel)",
            port: 3_000,
            url: "http://localhost:3000/?token=\(sentinel)"
        )
        var diagnosis = ProjectDiagnosis.notChecked(now: "2026-07-19T10:00:00Z")
        diagnosis.status = .failed
        diagnosis.summary = "Authorization: Bearer \(sentinel)"
        diagnosis.setCheck(
            .command,
            status: .fail,
            message: "Command leaked \(sentinel)",
            actions: [.revealCommand]
        )
        diagnosis.addTimeline(
            "Read /Users/example/private/\(sentinel)",
            status: .fail,
            at: "2026-07-19T10:01:00Z"
        )
        let runtime = RuntimeSnapshot(
            status: .failed,
            logs: Array(repeating: "password=\(sentinel)", count: 600),
            exitCode: 1,
            readinessMessage: "Cookie: session=\(sentinel)",
            diagnosis: diagnosis
        )

        let report = DoctorReportBuilder().report(
            project: draft,
            runtime: runtime,
            diagnosis: diagnosis
        )

        XCTAssertEqual(report.previewText, report.copyText)
        XCTAssertTrue(report.previewText.hasPrefix("LocalWrap Redacted Doctor Report"))
        XCTAssertTrue(report.previewText.contains("Command: fail"))
        XCTAssertTrue(report.previewText.contains("Runtime Status: failed"))
        XCTAssertTrue(report.previewText.contains("Exit Code: 1"))
        XCTAssertFalse(report.previewText.contains(sentinel))
        XCTAssertFalse(report.previewText.contains("/Users/example"))
        XCTAssertFalse(report.previewText.contains("npm start"))
        XCTAssertFalse(report.previewText.contains("localhost"))
        XCTAssertLessThanOrEqual(
            report.previewText.utf8.count,
            DoctorReportBuilder.maximumReportByteCount + 1
        )
    }
}
