import Foundation
import Observation
import ServiceManagement

@MainActor
protocol LaunchAtLoginControlling: AnyObject {
    var status: LaunchAtLoginStatus { get }

    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLaunchAtLoginController: LaunchAtLoginControlling {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
@Observable
final class LaunchAtLoginService {
    private(set) var status: LaunchAtLoginStatus
    private(set) var operation: LaunchAtLoginOperation = .idle
    private(set) var lastError: LaunchAtLoginServiceError?

    private let controller: any LaunchAtLoginControlling

    init(controller: any LaunchAtLoginControlling = SystemLaunchAtLoginController()) {
        self.controller = controller
        status = controller.status
    }

    var isRequested: Bool { status.isRequested }
    var isChanging: Bool { operation.isInProgress }

    func refresh() {
        status = controller.status
    }

    /// Applies the native `SMAppService.mainApp` state transition and returns
    /// an explicit result so callers cannot accidentally discard a failure.
    @discardableResult
    func setEnabled(
        _ enabled: Bool
    ) -> Result<LaunchAtLoginStatus, LaunchAtLoginServiceError> {
        guard !operation.isInProgress else {
            let error = LaunchAtLoginServiceError.operationInProgress
            lastError = error
            return .failure(error)
        }

        refresh()
        lastError = nil
        if enabled == status.isRequested {
            return .success(status)
        }
        guard status != .notFound else {
            let error = LaunchAtLoginServiceError.unavailable
            lastError = error
            return .failure(error)
        }

        operation = enabled ? .enabling : .disabling
        defer {
            status = controller.status
            operation = .idle
        }

        do {
            if enabled {
                try controller.register()
            } else {
                try controller.unregister()
            }
            return .success(controller.status)
        } catch {
            let detail = Self.conciseErrorDetail(error)
            let serviceError: LaunchAtLoginServiceError = enabled
                ? .enableFailed(detail)
                : .disableFailed(detail)
            lastError = serviceError
            return .failure(serviceError)
        }
    }

    func clearError() {
        lastError = nil
    }

    func openSystemSettings() {
        controller.openSystemSettings()
    }

    private static func conciseErrorDetail(_ error: Error) -> String {
        let fallback = "The system did not provide more information."
        let sanitized = error.localizedDescription.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format ? " " : String(scalar)
        }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let source = sanitized.isEmpty ? fallback : sanitized
        var result = ""
        var count = 0
        for character in source {
            let bytes = String(character).utf8.count
            guard count + bytes <= 180 else { break }
            result.append(character)
            count += bytes
        }
        return result.isEmpty ? fallback : result
    }
}

extension LaunchAtLoginService {
    /// Keeps ordinary unit fixtures and command-line entry points detached
    /// from Service Management. The native controller is installed only by
    /// the real application launch path.
    static func inactive() -> LaunchAtLoginService {
        LaunchAtLoginService(controller: InactiveLaunchAtLoginController())
    }
}

@MainActor
private final class InactiveLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus { .notFound }

    func register() throws { throw LaunchAtLoginServiceError.unavailable }
    func unregister() throws { throw LaunchAtLoginServiceError.unavailable }
    func openSystemSettings() {}
}
