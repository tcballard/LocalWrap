import XCTest
@testable import LocalWrapMac

@MainActor
final class RuntimeNotificationCoreTests: XCTestCase {
    func testOnlyExplicitOptInRequestsAuthorization() async {
        let preferences = FakeNotificationPreferences(isOptedIn: false)
        let delivery = FakeNotificationDelivery(status: .notDetermined)
        let service = RuntimeNotificationService(preferences: preferences, delivery: delivery)

        await service.refreshAuthorization()
        await service.observe(
            projects: [project()],
            runtimes: ["project": runtime(.ready, runID: "run-1")]
        )
        XCTAssertEqual(delivery.authorizationRequestCount, 0)

        await service.setOptedIn(true)
        XCTAssertEqual(delivery.authorizationRequestCount, 1)
        XCTAssertEqual(service.preferenceStatus, .enabled)
    }

    func testReadyDeliveryIsDeduplicatedAndProvidesInMemoryClickRoute() async throws {
        let (service, delivery) = enabledService()
        let project = project(id: "secret-id-42")
        await service.refreshAuthorization()
        await service.observe(
            projects: [project],
            runtimes: [project.id: runtime(.starting, runID: "run-1")]
        )
        await service.observe(
            projects: [project],
            runtimes: [project.id: runtime(.ready, runID: "run-1")]
        )
        await service.observe(
            projects: [project],
            runtimes: [project.id: runtime(.starting, runID: "run-1")]
        )
        await service.observe(
            projects: [project],
            runtimes: [project.id: runtime(.ready, runID: "run-1")]
        )

        let request = try XCTUnwrap(delivery.delivered.first)
        XCTAssertEqual(delivery.delivered.count, 1)
        XCTAssertFalse(request.identifier.contains(project.id))
        XCTAssertFalse(request.threadIdentifier.contains(project.id))
        XCTAssertEqual(
            service.navigationTarget(forNotificationIdentifier: request.identifier),
            .project(projectID: project.id, surface: .runtime)
        )
        XCTAssertTrue(
            service.notificationEventMatchesCurrentRuntime(
                identifier: request.identifier,
                projectID: project.id,
                runtime: runtime(.ready, runID: "run-1")
            )
        )
        XCTAssertFalse(
            service.notificationEventMatchesCurrentRuntime(
                identifier: request.identifier,
                projectID: project.id,
                runtime: runtime(.ready, runID: "run-2")
            )
        )
    }

    func testRecoveredReadinessIsQuietButLaterFailureNotifies() async {
        let (service, delivery) = enabledService()
        let project = project()
        var recoveredStarting = runtime(.starting, runID: "recovered")
        recoveredStarting.recoveredAfterRelaunch = true
        var recoveredReady = runtime(.ready, runID: "recovered")
        recoveredReady.recoveredAfterRelaunch = true
        var laterExit = runtime(
            .failed,
            runID: "recovered",
            reason: .unexpectedExit(code: 9)
        )
        laterExit.recoveredAfterRelaunch = true

        await service.refreshAuthorization()
        await service.observe(projects: [project], runtimes: [project.id: recoveredStarting])
        await service.observe(projects: [project], runtimes: [project.id: recoveredReady])
        XCTAssertTrue(delivery.delivered.isEmpty)

        await service.observe(projects: [project], runtimes: [project.id: laterExit])
        XCTAssertEqual(delivery.delivered.map(\.kind), [.unexpectedExit])
    }

    func testNotificationNameStripsBidiAndFormatControlsAndIsBounded() async throws {
        let (service, delivery) = enabledService()
        let maliciousName = "\u{202E}API\u{200D}\n" + String(repeating: "é", count: 100)
        let project = project(name: maliciousName)

        await service.refreshAuthorization()
        await service.observe(
            projects: [project],
            runtimes: [project.id: runtime(.starting, runID: "run")]
        )
        await service.observe(
            projects: [project],
            runtimes: [project.id: runtime(.ready, runID: "run")]
        )

        let body = try XCTUnwrap(delivery.delivered.first?.body)
        XCTAssertLessThanOrEqual(body.utf8.count, 91)
        XCTAssertFalse(body.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || $0.properties.generalCategory == .format
        })
    }

    func testDeliveryFailureIsObservableAndSanitized() async {
        let preferences = FakeNotificationPreferences(isOptedIn: true)
        let delivery = FakeNotificationDelivery(status: .authorized)
        delivery.deliveryError = FakeNotificationError(
            detail: "rejected\n\u{202E}" + String(repeating: "x", count: 500)
        )
        let service = RuntimeNotificationService(preferences: preferences, delivery: delivery)
        let project = project()

        await service.refreshAuthorization()
        await service.observe(
            projects: [project],
            runtimes: [project.id: runtime(.starting, runID: "run")]
        )
        await service.observe(
            projects: [project],
            runtimes: [project.id: runtime(.ready, runID: "run")]
        )

        guard case .deliveryFailed(let detail) = service.lastError else {
            return XCTFail("Expected an observable delivery failure")
        }
        XCTAssertLessThanOrEqual(detail.utf8.count, 180)
        XCTAssertFalse(detail.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || $0.properties.generalCategory == .format
        })
    }

    private func enabledService() -> (
        RuntimeNotificationService,
        FakeNotificationDelivery
    ) {
        let preferences = FakeNotificationPreferences(isOptedIn: true)
        let delivery = FakeNotificationDelivery(status: .authorized)
        return (
            RuntimeNotificationService(preferences: preferences, delivery: delivery),
            delivery
        )
    }

    private func project(id: String = "project", name: String = "Project") -> Project {
        Project(
            id: id,
            name: name,
            cwd: "/private/project",
            command: "npm start",
            port: 9_000,
            url: "http://localhost:9000",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
    }

    private func runtime(
        _ status: RuntimeStatus,
        runID: String?,
        reason: RuntimeTerminalReason? = nil
    ) -> RuntimeSnapshot {
        var snapshot = RuntimeSnapshot()
        snapshot.status = status
        snapshot.runID = runID
        snapshot.terminalReason = reason
        return snapshot
    }
}

@MainActor
private final class FakeNotificationPreferences: RuntimeNotificationPreferenceStoring {
    var isOptedIn: Bool
    init(isOptedIn: Bool) { self.isOptedIn = isOptedIn }
}

@MainActor
private final class FakeNotificationDelivery: RuntimeNotificationDelivering {
    var status: LocalNotificationAuthorizationStatus
    var authorizationResult = true
    var deliveryError: Error?
    private(set) var authorizationRequestCount = 0
    private(set) var delivered: [RuntimeNotificationRequest] = []

    init(status: LocalNotificationAuthorizationStatus) { self.status = status }

    func authorizationStatus() async -> LocalNotificationAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        status = authorizationResult ? .authorized : .denied
        return authorizationResult
    }

    func deliver(_ request: RuntimeNotificationRequest) async throws {
        if let deliveryError { throw deliveryError }
        delivered.append(request)
    }
}

private struct FakeNotificationError: Error, LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}
