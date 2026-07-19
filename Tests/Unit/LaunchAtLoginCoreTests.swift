import XCTest
@testable import LocalWrapMac

@MainActor
final class LaunchAtLoginCoreTests: XCTestCase {
    func testRegisterUsesNativeRequestedStateSemantics() throws {
        let controller = FakeLaunchAtLoginController(status: .notRegistered)
        let service = LaunchAtLoginService(controller: controller)

        let result = service.setEnabled(true)

        XCTAssertEqual(try result.get(), .enabled)
        XCTAssertEqual(controller.registerCallCount, 1)
        XCTAssertTrue(service.isRequested)
        XCTAssertEqual(service.operation, .idle)
    }

    func testRequiresApprovalIsAlreadyRequestedAndCanBeUnregistered() throws {
        let controller = FakeLaunchAtLoginController(status: .requiresApproval)
        let service = LaunchAtLoginService(controller: controller)

        XCTAssertEqual(try service.setEnabled(true).get(), .requiresApproval)
        XCTAssertEqual(controller.registerCallCount, 0)
        XCTAssertEqual(try service.setEnabled(false).get(), .notRegistered)
        XCTAssertEqual(controller.unregisterCallCount, 1)
    }

    func testNotFoundFailsExplicitlyWithoutCallingServiceManagementMutation() {
        let controller = FakeLaunchAtLoginController(status: .notFound)
        let service = LaunchAtLoginService(controller: controller)

        let result = service.setEnabled(true)

        XCTAssertEqual(result, .failure(.unavailable))
        XCTAssertEqual(service.lastError, .unavailable)
        XCTAssertEqual(controller.registerCallCount, 0)
        XCTAssertEqual(controller.unregisterCallCount, 0)
    }

    func testFailureDetailIsSingleLineFormatSafeAndByteBounded() {
        let controller = FakeLaunchAtLoginController(status: .notRegistered)
        controller.registerError = FakeLaunchAtLoginError(
            detail: "rejected\n\u{202E}" + String(repeating: "x", count: 500)
        )
        let service = LaunchAtLoginService(controller: controller)

        _ = service.setEnabled(true)

        guard case .enableFailed(let detail) = service.lastError else {
            return XCTFail("Expected enable failure")
        }
        XCTAssertLessThanOrEqual(detail.utf8.count, 180)
        XCTAssertFalse(detail.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || $0.properties.generalCategory == .format
        })
    }

    func testSettingsAffordanceUsesNativeLoginItemsPaneController() {
        let controller = FakeLaunchAtLoginController(status: .requiresApproval)
        let service = LaunchAtLoginService(controller: controller)

        service.openSystemSettings()

        XCTAssertEqual(controller.openSystemSettingsCallCount, 1)
    }
}

@MainActor
private final class FakeLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSystemSettingsCallCount = 0

    init(status: LaunchAtLoginStatus) { self.status = status }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openSystemSettings() { openSystemSettingsCallCount += 1 }
}

private struct FakeLaunchAtLoginError: Error, LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}
