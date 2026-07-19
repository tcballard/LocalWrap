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

    func testNavigationPolicyOnlyOpensUserActivatedMainFrameLinksExternally() {
        let policy = PreviewNavigationPolicy()
        let external = URL(string: "https://example.com/docs")!

        XCTAssertEqual(policy.decision(for: PreviewNavigationContext(
            url: external,
            isMainFrame: true,
            isUserActivated: true
        )), .openExternal(external))
        XCTAssertEqual(policy.decision(for: PreviewNavigationContext(
            url: external,
            isMainFrame: true,
            isUserActivated: false
        )), .cancel)
        XCTAssertEqual(policy.decision(for: PreviewNavigationContext(
            url: external,
            isMainFrame: false,
            isUserActivated: true
        )), .cancel)
        XCTAssertEqual(policy.decision(for: PreviewNavigationContext(
            url: URL(string: "http://localhost:3000/frame"),
            isMainFrame: false,
            isUserActivated: false
        )), .allow)
    }

    func testNavigationContextUsesDestinationFrameAndMainFrameNewWindows() {
        let url = URL(string: "https://example.com/docs")!

        XCTAssertFalse(PreviewNavigationContext.resolvingWebKitFrames(
            url: url,
            targetFrameIsMain: false,
            sourceFrameIsMain: true,
            isUserActivated: false
        ).isMainFrame)
        XCTAssertTrue(PreviewNavigationContext.resolvingWebKitFrames(
            url: url,
            targetFrameIsMain: nil,
            sourceFrameIsMain: true,
            isUserActivated: true
        ).isMainFrame)
        XCTAssertFalse(PreviewNavigationContext.resolvingWebKitFrames(
            url: url,
            targetFrameIsMain: nil,
            sourceFrameIsMain: false,
            isUserActivated: true
        ).isMainFrame)
    }

    func testPreviewStateOpenReloadAndCloseAreDeterministic() {
        let url = URL(string: "http://localhost:3000")!
        var state = PreviewState()

        state.open(url)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.status, .loading)
        XCTAssertEqual(state.currentURL, url)

        state.markLoaded()
        state.reload()
        XCTAssertEqual(state.reloadToken, 1)
        XCTAssertEqual(state.status, .ready)

        state.close()
        XCTAssertEqual(state, PreviewState())
    }

    func testPreviewStateNavigationRequestsAreGuardedByAvailability() {
        let url = URL(string: "http://localhost:3000")!
        var state = PreviewState()

        state.goBack()
        state.goForward()
        state.stopLoading()
        XCTAssertEqual(state.backToken, 0)
        XCTAssertEqual(state.forwardToken, 0)
        XCTAssertEqual(state.stopToken, 0)

        state.open(url)
        state.goBack()
        state.goForward()
        XCTAssertEqual(state.backToken, 0)
        XCTAssertEqual(state.forwardToken, 0)

        state.canGoBack = true
        state.canGoForward = true
        state.markLoaded()
        state.goBack()
        state.goForward()

        XCTAssertEqual(state.backToken, 1)
        XCTAssertEqual(state.forwardToken, 1)
        XCTAssertEqual(state.status, .ready)

        state.markLoading()
        state.stopLoading()
        XCTAssertEqual(state.stopToken, 1)
    }

    func testPreviewStateAppliesClampedWebSnapshotAndLoadLifecycle() {
        let initialURL = URL(string: "http://localhost:3000")!
        let navigatedURL = URL(string: "http://localhost:3000/dashboard")!
        var state = PreviewState()
        state.open(initialURL)

        state.apply(PreviewWebSnapshot(
            currentURL: navigatedURL,
            pageTitle: "Dashboard",
            canGoBack: true,
            canGoForward: false,
            estimatedProgress: 1.4,
            isLoading: true
        ))

        XCTAssertEqual(state.currentURL, navigatedURL)
        XCTAssertEqual(state.pageTitle, "Dashboard")
        XCTAssertTrue(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
        XCTAssertEqual(state.estimatedProgress, 1)
        XCTAssertEqual(state.status, .loading)
        XCTAssertFalse(state.hasLoadedContent)

        state.markLoaded()
        XCTAssertEqual(state.status, .ready)
        XCTAssertTrue(state.hasLoadedContent)
        XCTAssertEqual(state.estimatedProgress, 1)

        state.markFailed("Connection lost")
        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.errorMessage, "Connection lost")
        XCTAssertTrue(state.hasLoadedContent)
    }

    func testAttentionFailureEvidenceExcludesOrdinaryWebViewStateNoise() {
        let url = URL(string: "http://localhost:3000")!
        var state = PreviewState()
        state.open(url)
        XCTAssertNil(state.attentionFailureEvidence)

        state.markFailed("Connection lost")
        let failure = state.attentionFailureEvidence

        state.pageTitle = "A later title"
        state.estimatedProgress = 0.75
        state.canGoBack = true
        state.reload()
        XCTAssertEqual(state.attentionFailureEvidence, failure)

        state.markFailed("Connection refused")
        XCTAssertNotEqual(state.attentionFailureEvidence, failure)

        state.markLoading()
        XCTAssertNil(state.attentionFailureEvidence)
    }

    func testViewportPresetsExposeStableResponsiveWidths() {
        XCTAssertEqual(PreviewViewportPreset.allCases, [.fit, .compact, .tablet, .desktop])
        XCTAssertNil(PreviewViewportPreset.fit.width)
        XCTAssertEqual(PreviewViewportPreset.compact.width, 390)
        XCTAssertEqual(PreviewViewportPreset.tablet.width, 768)
        XCTAssertEqual(PreviewViewportPreset.desktop.width, 1_280)
        XCTAssertEqual(PreviewViewportPreset.fit.accessibilityValue, "Fit to available width")
        XCTAssertEqual(PreviewViewportPreset.compact.label, "Phone")
        XCTAssertEqual(PreviewViewportPreset.compact.accessibilityValue, "390 points wide")
    }
}
