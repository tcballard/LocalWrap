import Foundation
import XCTest
@testable import LocalWrapMac

final class ReleaseCheckServiceTests: XCTestCase {
    func testNewerStableReleaseReturnsTrustedUpdateAndSendsGitHubHeaders() async throws {
        let recorder = RequestRecorder()
        let service = ReleaseCheckService { request in
            await recorder.record(request)
            return try response(
                request: request,
                status: 200,
                body: releaseJSON(tag: "v3.4.0")
            )
        }

        let outcome = try await service.check(currentVersion: "3.3.0")

        XCTAssertEqual(
            outcome,
            .updateAvailable(
                currentVersion: "3.3.0",
                latestVersion: "3.4.0",
                releaseURL: URL(string: "https://github.com/tcballard/LocalWrap/releases/tag/v3.4.0")!
            )
        )
        let request = await recorder.request
        XCTAssertEqual(request?.url, ReleaseCheckService.latestReleaseURL)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "LocalWrapMac/3.3.0")
    }

    func testEqualOrOlderLatestReleaseIsUpToDate() async throws {
        for tag in ["3.3.0", "v3.2.9"] {
            let service = ReleaseCheckService { request in
                try response(request: request, status: 200, body: releaseJSON(tag: tag))
            }
            let outcome = try await service.check(currentVersion: "v3.3.0")
            guard case .upToDate(let current, let latest) = outcome else {
                return XCTFail("Expected up-to-date outcome for \(tag)")
            }
            XCTAssertEqual(current, "3.3.0")
            XCTAssertEqual(latest, tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
        }
    }

    func testRejectsPrereleaseMalformedMetadataUntrustedURLAndHTTPFailure() async {
        let cases: [(Int, String, ReleaseCheckError)] = [
            (403, "{}", .httpStatus(403)),
            (200, releaseJSON(tag: "next"), .invalidRelease),
            (200, releaseJSON(tag: "3.4.0", prerelease: true), .invalidRelease),
            (
                200,
                releaseJSON(
                    tag: "3.4.0",
                    htmlURL: "https://example.com/tcballard/LocalWrap/releases/tag/v3.4.0"
                ),
                .untrustedReleaseURL
            ),
        ]

        for (status, body, expected) in cases {
            let service = ReleaseCheckService { request in
                try response(request: request, status: status, body: body)
            }
            do {
                _ = try await service.check(currentVersion: "3.3.0")
                XCTFail("Expected \(expected)")
            } catch let error as ReleaseCheckError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsInvalidInstalledVersionBeforeRequesting() async {
        let service = ReleaseCheckService { _ in
            XCTFail("Fetch should not be called")
            throw ReleaseCheckError.invalidResponse
        }
        do {
            _ = try await service.check(currentVersion: "development")
            XCTFail("Expected invalid version")
        } catch let error as ReleaseCheckError {
            XCTAssertEqual(error, .invalidCurrentVersion("development"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor RequestRecorder {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}

private func response(request: URLRequest, status: Int, body: String) throws -> (Data, URLResponse) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
}

private func releaseJSON(
    tag: String,
    htmlURL: String? = nil,
    prerelease: Bool = false
) -> String {
    let url = htmlURL ?? "https://github.com/tcballard/LocalWrap/releases/tag/\(tag)"
    return """
    {
      "tag_name": "\(tag)",
      "html_url": "\(url)",
      "draft": false,
      "prerelease": \(prerelease)
    }
    """
}
