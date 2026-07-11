import Foundation
import XCTest
@testable import LocalWrapMac

final class PreviewTests: XCTestCase {
    func testNavigationPolicyKeepsOnlyValidatedLocalHTTPInsidePreview() {
        let policy = PreviewNavigationPolicy()

        XCTAssertEqual(
            policy.decision(for: URL(string: "http://localhost:3000/dashboard")),
            .allow
        )
        XCTAssertEqual(
            policy.decision(for: URL(string: "https://127.0.0.1:8443/")),
            .allow
        )
        XCTAssertEqual(
            policy.decision(for: URL(string: "http://[::1]:4321/")),
            .allow
        )
        XCTAssertEqual(
            policy.decision(for: URL(string: "https://example.com/docs")),
            .openExternal(URL(string: "https://example.com/docs")!)
        )
        XCTAssertEqual(policy.decision(for: URL(string: "file:///tmp/secret")), .cancel)
        XCTAssertEqual(policy.decision(for: URL(string: "http://localhost/")), .cancel)
        XCTAssertEqual(policy.decision(for: URL(string: "http://localhost:999/")), .cancel)
        XCTAssertEqual(policy.decision(for: URL(string: "javascript:alert(1)")), .cancel)
        XCTAssertEqual(policy.decision(for: nil), .cancel)

        XCTAssertTrue(policy.allowsResponse(
            url: URL(string: "http://localhost:3000/app"),
            canShowMIMEType: true,
            contentDisposition: nil
        ))
        XCTAssertFalse(policy.allowsResponse(
            url: URL(string: "http://localhost:3000/archive.zip"),
            canShowMIMEType: false,
            contentDisposition: nil
        ))
        XCTAssertFalse(policy.allowsResponse(
            url: URL(string: "http://localhost:3000/report.pdf"),
            canShowMIMEType: true,
            contentDisposition: "attachment; filename=report.pdf"
        ))
    }

    func testPreviewStateOpenReloadAndCloseAreDeterministic() {
        let url = URL(string: "http://localhost:3000")!
        var state = PreviewState()

        state.open(url)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.status, .loading)
        XCTAssertEqual(state.currentURL, url)

        state.reload()
        XCTAssertEqual(state.reloadToken, 1)
        XCTAssertEqual(state.status, .loading)

        state.close()
        XCTAssertEqual(state, PreviewState())
    }
}
