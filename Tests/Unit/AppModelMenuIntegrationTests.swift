import AppKit
import XCTest
@testable import LocalWrapMac

@MainActor
final class AppModelMenuIntegrationTests: XCTestCase {
    func testAppDelegateRetainsClosedMainWindowForMenuRestoration() throws {
        let delegate = AppDelegate()
        weak var retainedWindow: NSWindow?

        autoreleasepool {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            delegate.registerMainWindow(window)
            retainedWindow = window
        }

        let window = try XCTUnwrap(retainedWindow)
        XCTAssertFalse(window.isVisible)

        delegate.showMainWindow()

        XCTAssertTrue(window.isVisible)
        window.orderOut(nil)
    }

    func testUnavailableMenuActionPublishesFailureForHiddenWindowRecovery() {
        let project = makeProject(id: "stopped")
        let model = AppModel(
            projects: [project],
            initialMenuProjectPolicies: [project.id: validPolicy(project.id)]
        )
        let before = model.menuActionFailureRevision

        model.executeMenuProjectAction(projectID: project.id, action: .stop)

        XCTAssertGreaterThan(model.menuActionFailureRevision, before)
        XCTAssertEqual(model.errorMessage, "Project is not running.")
    }

    func testAsynchronousMenuStartFailurePublishesFailure() async throws {
        let project = makeProject(id: "missing", cwd: "/localwrap/definitely/missing")
        let model = AppModel(
            projects: [project],
            initialMenuProjectPolicies: [project.id: validPolicy(project.id)]
        )
        let before = model.menuActionFailureRevision

        model.executeMenuProjectAction(projectID: project.id, action: .start)

        for _ in 0..<100 where model.menuActionFailureRevision == before {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(model.menuActionFailureRevision, before)
        XCTAssertNotNil(model.errorMessage)
    }

    func testNotificationClickPrefersCurrentRuntimeAttentionIssue() async throws {
        let project = makeProject(id: "failed")
        let preferences = MenuNotificationPreferences()
        let delivery = MenuNotificationDelivery()
        let notifications = RuntimeNotificationService(
            preferences: preferences,
            delivery: delivery
        )
        await notifications.refreshAuthorization()

        var starting = RuntimeSnapshot()
        starting.status = .starting
        starting.runID = "run"
        var failed = RuntimeSnapshot()
        failed.status = .failed
        failed.runID = "run"
        failed.terminalReason = .unexpectedExit(code: 9)
        await notifications.observe(projects: [project], runtimes: [project.id: starting])
        await notifications.observe(projects: [project], runtimes: [project.id: failed])

        let identifier = try XCTUnwrap(delivery.delivered.first?.identifier)
        let target = AttentionNavigationTarget.project(
            projectID: project.id,
            surface: .doctor(check: .process, suggestedAction: nil)
        )
        let issue = AttentionIssue(
            id: "runtime-failure",
            severity: .blocker,
            sources: [.runtime],
            scope: .project(id: project.id, name: project.name),
            title: "Runtime failed",
            consequence: "Review the failed runtime.",
            nextAction: AttentionNextAction(
                label: "Review",
                kind: .navigate,
                requiresConfirmation: false
            ),
            navigationTarget: target
        )
        let model = AppModel(
            projects: [project],
            initialRuntimes: [project.id: failed],
            initialAttentionSnapshot: AttentionSnapshot(
                generatedAt: "2026-07-19T12:00:00Z",
                issues: [issue],
                history: []
            ),
            runtimeNotificationService: notifications
        )

        model.handleNotificationResponse(identifier: identifier)

        XCTAssertEqual(model.navigationRouter.selection, .project(project.id))
        XCTAssertEqual(model.navigationRouter.attentionRequest?.target, target)
    }

    func testNotificationClickRoutesStaleRunToRuntimeSurface() async throws {
        let project = makeProject(id: "failed")
        let (notifications, delivery) = await makeNotifications(
            project: project,
            runID: "old-run",
            reason: .unexpectedExit(code: 9)
        )
        let identifier = try XCTUnwrap(delivery.delivered.first?.identifier)
        var currentRuntime = RuntimeSnapshot()
        currentRuntime.status = .failed
        currentRuntime.runID = "new-run"
        currentRuntime.terminalReason = .unexpectedExit(code: 9)
        let issue = runtimeIssue(for: project)
        let model = makeNotificationModel(
            project: project,
            runtime: currentRuntime,
            issue: issue,
            notifications: notifications
        )

        model.handleNotificationResponse(identifier: identifier)

        XCTAssertEqual(model.navigationRouter.selection, .project(project.id))
        XCTAssertEqual(
            model.navigationRouter.attentionRequest?.target,
            .project(projectID: project.id, surface: .runtime)
        )
        XCTAssertNotEqual(model.navigationRouter.attentionRequest?.target, issue.navigationTarget)
    }

    func testNotificationClickRoutesStaleEventToRuntimeSurface() async throws {
        let project = makeProject(id: "failed")
        let (notifications, delivery) = await makeNotifications(
            project: project,
            runID: "same-run",
            reason: .launchFailure
        )
        let identifier = try XCTUnwrap(delivery.delivered.first?.identifier)
        var currentRuntime = RuntimeSnapshot()
        currentRuntime.status = .failed
        currentRuntime.runID = "same-run"
        currentRuntime.terminalReason = .unexpectedExit(code: 9)
        let issue = runtimeIssue(for: project)
        let model = makeNotificationModel(
            project: project,
            runtime: currentRuntime,
            issue: issue,
            notifications: notifications
        )

        model.handleNotificationResponse(identifier: identifier)

        XCTAssertEqual(model.navigationRouter.selection, .project(project.id))
        XCTAssertEqual(
            model.navigationRouter.attentionRequest?.target,
            .project(projectID: project.id, surface: .runtime)
        )
        XCTAssertNotEqual(model.navigationRouter.attentionRequest?.target, issue.navigationTarget)
    }

    private func makeNotifications(
        project: Project,
        runID: String,
        reason: RuntimeTerminalReason
    ) async -> (RuntimeNotificationService, MenuNotificationDelivery) {
        let preferences = MenuNotificationPreferences()
        let delivery = MenuNotificationDelivery()
        let notifications = RuntimeNotificationService(
            preferences: preferences,
            delivery: delivery
        )
        await notifications.refreshAuthorization()
        var starting = RuntimeSnapshot()
        starting.status = .starting
        starting.runID = runID
        var failed = RuntimeSnapshot()
        failed.status = .failed
        failed.runID = runID
        failed.terminalReason = reason
        await notifications.observe(projects: [project], runtimes: [project.id: starting])
        await notifications.observe(projects: [project], runtimes: [project.id: failed])
        return (notifications, delivery)
    }

    private func runtimeIssue(for project: Project) -> AttentionIssue {
        AttentionIssue(
            id: "runtime-failure",
            severity: .blocker,
            sources: [.runtime],
            scope: .project(id: project.id, name: project.name),
            title: "Runtime failed",
            consequence: "Review the failed runtime.",
            nextAction: AttentionNextAction(
                label: "Review",
                kind: .navigate,
                requiresConfirmation: false
            ),
            navigationTarget: .project(
                projectID: project.id,
                surface: .doctor(check: .process, suggestedAction: nil)
            )
        )
    }

    private func makeNotificationModel(
        project: Project,
        runtime: RuntimeSnapshot,
        issue: AttentionIssue,
        notifications: RuntimeNotificationService
    ) -> AppModel {
        AppModel(
            projects: [project],
            initialRuntimes: [project.id: runtime],
            initialAttentionSnapshot: AttentionSnapshot(
                generatedAt: "2026-07-19T12:00:00Z",
                issues: [issue],
                history: []
            ),
            runtimeNotificationService: notifications
        )
    }

    private func makeProject(
        id: String,
        cwd: String = "/tmp"
    ) -> Project {
        Project(
            id: id,
            name: "Project \(id)",
            cwd: cwd,
            command: "npm start",
            port: 4_321,
            url: "http://localhost:4321",
            createdAt: "2026-07-19T12:00:00Z",
            updatedAt: "2026-07-19T12:00:00Z"
        )
    }

    private func validPolicy(_ projectID: String) -> MenuProjectValidatedPolicy {
        MenuProjectValidatedPolicy(
            projectID: projectID,
            configuration: .valid,
            canOpenValidatedLocalURL: true,
            signalling: .unavailable(.noOwnedProcess)
        )
    }
}

@MainActor
private final class MenuNotificationPreferences: RuntimeNotificationPreferenceStoring {
    var isOptedIn = true
}

@MainActor
private final class MenuNotificationDelivery: RuntimeNotificationDelivering {
    private(set) var delivered: [RuntimeNotificationRequest] = []

    func authorizationStatus() async -> LocalNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func deliver(_ request: RuntimeNotificationRequest) async throws {
        delivered.append(request)
    }
}
