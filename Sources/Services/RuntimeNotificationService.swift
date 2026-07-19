import CryptoKit
import Foundation
import Observation
import UserNotifications

@MainActor
protocol RuntimeNotificationPreferenceStoring: AnyObject {
    var isOptedIn: Bool { get set }
}

@MainActor
final class UserDefaultsRuntimeNotificationPreferenceStore: RuntimeNotificationPreferenceStoring {
    static let preferenceKey = "LocalWrap.runtimeNotifications.optedIn"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isOptedIn: Bool {
        get { defaults.bool(forKey: Self.preferenceKey) }
        set { defaults.set(newValue, forKey: Self.preferenceKey) }
    }
}

@MainActor
protocol RuntimeNotificationDelivering: AnyObject {
    func authorizationStatus() async -> LocalNotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func deliver(_ request: RuntimeNotificationRequest) async throws
}

@MainActor
final class UserNotificationCenterRuntimeDelivery: RuntimeNotificationDelivering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func authorizationStatus() async -> LocalNotificationAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let status: LocalNotificationAuthorizationStatus
                switch settings.authorizationStatus {
                case .notDetermined: status = .notDetermined
                case .denied: status = .denied
                case .authorized: status = .authorized
                case .provisional: status = .provisional
                @unknown default: status = .unknown
                }
                continuation.resume(returning: status)
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    func deliver(_ request: RuntimeNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadIdentifier
        content.interruptionLevel = .active
        // Deliberately no userInfo: click routing is held in memory only.
        let notification = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: nil
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            center.add(notification) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}

@MainActor
@Observable
final class RuntimeNotificationService {
    private static let maximumRememberedEvents = 512
    private static let maximumNavigationRoutes = 256

    private(set) var isOptedIn: Bool
    private(set) var authorizationStatus: LocalNotificationAuthorizationStatus = .unknown
    private(set) var preferenceStatus: RuntimeNotificationPreferenceStatus
    private(set) var lastError: RuntimeNotificationServiceError?
    private(set) var deliveredNotificationCount = 0

    private let preferences: any RuntimeNotificationPreferenceStoring
    private let delivery: any RuntimeNotificationDelivering
    private var observedStates: [String: ObservedRuntimeState]?
    private var deliveredIdentifiers = Set<String>()
    private var deliveredIdentifierOrder: [String] = []
    private var navigationRoutes: [String: RuntimeNotificationRoute] = [:]
    private var navigationRouteOrder: [String] = []

    init(
        preferences: any RuntimeNotificationPreferenceStoring =
            UserDefaultsRuntimeNotificationPreferenceStore(),
        delivery: any RuntimeNotificationDelivering = UserNotificationCenterRuntimeDelivery()
    ) {
        self.preferences = preferences
        self.delivery = delivery
        isOptedIn = preferences.isOptedIn
        preferenceStatus = preferences.isOptedIn ? .checkingAuthorization : .disabled
    }

    var canDeliver: Bool { isOptedIn && authorizationStatus.permitsDelivery }

    func refreshAuthorization() async {
        guard isOptedIn else { preferenceStatus = .disabled; return }
        lastError = nil
        preferenceStatus = .checkingAuthorization
        authorizationStatus = await delivery.authorizationStatus()
        updatePreferenceStatus()
    }

    /// The only path that requests authorization; observation never prompts.
    func setOptedIn(_ optedIn: Bool) async {
        lastError = nil
        if !optedIn {
            preferences.isOptedIn = false
            isOptedIn = false
            preferenceStatus = .disabled
            return
        }
        preferences.isOptedIn = true
        isOptedIn = true
        authorizationStatus = await delivery.authorizationStatus()
        guard authorizationStatus == .notDetermined || authorizationStatus == .unknown else {
            updatePreferenceStatus()
            return
        }
        preferenceStatus = .requestingAuthorization
        do {
            let granted = try await delivery.requestAuthorization()
            authorizationStatus = granted ? .authorized : .denied
            updatePreferenceStatus()
        } catch {
            authorizationStatus = await delivery.authorizationStatus()
            updatePreferenceStatus()
            lastError = .authorizationFailed(Self.conciseErrorDetail(error))
        }
    }

    /// First observation is a quiet baseline. Recovered readiness is also
    /// quiet, while a later failure remains a real, one-shot transition.
    func observe(projects: [Project], runtimes: [String: RuntimeSnapshot]) async {
        let names = projects.reduce(into: [String: String]()) { result, project in
            if result[project.id] == nil { result[project.id] = project.name }
        }
        let projectIDs = Set(names.keys).union(runtimes.keys)
        let current = Dictionary(uniqueKeysWithValues: projectIDs.map {
            ($0, Self.observedState(for: runtimes[$0]))
        })
        guard let previous = observedStates else { observedStates = current; return }
        observedStates = current
        guard canDeliver else { return }

        let events = projectIDs.sorted().compactMap { projectID -> NotificationEvent? in
            guard let old = previous[projectID], let new = current[projectID], old != new,
                  !Self.isRecoveredReadyTransition(old: old, new: new, runtime: runtimes[projectID]),
                  let name = names[projectID],
                  let event = Self.notification(projectID: projectID, projectName: name, state: new),
                  !deliveredIdentifiers.contains(event.request.identifier) else { return nil }
            return event
        }

        var failure: RuntimeNotificationServiceError?
        for event in events {
            do {
                try await delivery.deliver(event.request)
                rememberDelivered(event.request.identifier)
                rememberNavigation(event.route, for: event.request.identifier)
                deliveredNotificationCount += 1
            } catch {
                failure = failure ?? .deliveryFailed(Self.conciseErrorDetail(error))
            }
        }
        if !events.isEmpty { lastError = failure }
    }

    func navigationTarget(
        forNotificationIdentifier identifier: String
    ) -> AttentionNavigationTarget? {
        navigationRoutes[identifier]?.target
    }

    /// Notification identifiers carry no navigation metadata. This compares
    /// the current runtime with the bounded, process-local event identity that
    /// was remembered only after successful delivery.
    func notificationEventMatchesCurrentRuntime(
        identifier: String,
        projectID: String,
        runtime: RuntimeSnapshot
    ) -> Bool {
        guard let route = navigationRoutes[identifier], route.projectID == projectID else {
            return false
        }
        return route.semanticState == Self.observedState(for: runtime)
    }

    func clearError() { lastError = nil }

    private func rememberDelivered(_ id: String) {
        guard deliveredIdentifiers.insert(id).inserted else { return }
        deliveredIdentifierOrder.append(id)
        while deliveredIdentifierOrder.count > Self.maximumRememberedEvents {
            deliveredIdentifiers.remove(deliveredIdentifierOrder.removeFirst())
        }
    }

    private func rememberNavigation(_ route: RuntimeNotificationRoute, for id: String) {
        if navigationRoutes[id] == nil { navigationRouteOrder.append(id) }
        navigationRoutes[id] = route
        while navigationRouteOrder.count > Self.maximumNavigationRoutes {
            navigationRoutes.removeValue(forKey: navigationRouteOrder.removeFirst())
        }
    }

    private func updatePreferenceStatus() {
        guard isOptedIn else { preferenceStatus = .disabled; return }
        preferenceStatus = authorizationStatus.permitsDelivery
            ? .enabled : .requiresSystemApproval
    }

    private static func notification(
        projectID: String,
        projectName: String,
        state: ObservedRuntimeState
    ) -> NotificationEvent? {
        let kind: RuntimeNotificationKind
        let title: String
        let suffix: String
        let identity: String
        switch state {
        case .ready(let run):
            (kind, title, suffix, identity) = (.ready, "Ready", "is ready.", run)
        case .failed(let run, let reason):
            (kind, title, suffix, identity) = (.failed, "Failed", "failed.", "\(run)|\(reason)")
        case .unexpectedExit(let run, let code):
            (kind, title, suffix, identity) =
                (.unexpectedExit, "Unexpected Exit", "exited unexpectedly.", "\(run)|\(code)")
        case .inactive, .active:
            return nil
        }
        let request = RuntimeNotificationRequest(
            identifier: stableIdentifier(
                prefix: "event",
                semanticValue: "\(projectID)|\(kind.rawValue)|\(identity)"
            ),
            threadIdentifier: stableIdentifier(prefix: "project", semanticValue: projectID),
            kind: kind,
            title: title,
            body: "\(boundedProjectName(projectName)) \(suffix)"
        )
        return NotificationEvent(
            request: request,
            route: RuntimeNotificationRoute(
                projectID: projectID,
                semanticState: state
            )
        )
    }

    private static func observedState(for runtime: RuntimeSnapshot?) -> ObservedRuntimeState {
        guard let runtime else { return .inactive }
        let run = runtime.runID ?? "no-run"
        if runtime.status == .ready { return .ready(run: run) }
        if runtime.status == .failed {
            if case .unexpectedExit(let code) = runtime.terminalReason {
                return .unexpectedExit(run: run, code: code.map(String.init) ?? "unknown")
            }
            return .failed(run: run, reason: stableFailureReason(runtime.terminalReason))
        }
        return runtime.status.isActive ? .active(run: runtime.runID, status: runtime.status) : .inactive
    }

    private static func stableFailureReason(_ reason: RuntimeTerminalReason?) -> String {
        switch reason {
        case .intentionalStop: "intentional-stop"
        case .launchFailure: "launch-failure"
        case .doctorBlocked: "doctor-blocked"
        case .readinessTimeout: "readiness-timeout"
        case .cleanupFailure: "cleanup-failure"
        case .unexpectedExit(let code): "unexpected-exit-\(code.map(String.init) ?? "unknown")"
        case .ownershipConflict: "ownership-conflict"
        case .ownershipUnverifiable: "ownership-unverifiable"
        case nil: "unspecified"
        }
    }

    private static func isRecoveredReadyTransition(
        old: ObservedRuntimeState,
        new: ObservedRuntimeState,
        runtime: RuntimeSnapshot?
    ) -> Bool {
        guard runtime?.recoveredAfterRelaunch == true, case .ready(let run) = new else {
            return false
        }
        switch old {
        case .active(let previousRun, _): return previousRun == run
        case .ready(let previousRun): return previousRun == run
        case .inactive, .failed, .unexpectedExit: return false
        }
    }

    private static func boundedProjectName(_ value: String) -> String {
        boundedSafeText(value, fallback: "A local project", maximumBytes: 80)
    }

    private static func boundedSafeText(
        _ value: String,
        fallback: String,
        maximumBytes: Int
    ) -> String {
        let clean = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format ? " " : String(scalar)
        }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let source = clean.isEmpty ? fallback : clean
        var result = ""
        var count = 0
        for character in source {
            let bytes = String(character).utf8.count
            guard count + bytes <= maximumBytes else { break }
            result.append(character)
            count += bytes
        }
        return result.isEmpty ? fallback : result
    }

    private static func stableIdentifier(prefix: String, semanticValue: String) -> String {
        let digest = SHA256.hash(data: Data(semanticValue.utf8))
        return "localwrap.runtime.\(prefix).\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    private static func conciseErrorDetail(_ error: Error) -> String {
        boundedSafeText(
            error.localizedDescription,
            fallback: "The system did not provide more information.",
            maximumBytes: 180
        )
    }
}

extension RuntimeNotificationService {
    /// A process-local, non-delivering service for tests and CLI execution.
    /// The application launch path replaces this with UserNotifications.
    static func inactive() -> RuntimeNotificationService {
        RuntimeNotificationService(
            preferences: InactiveRuntimeNotificationPreferences(),
            delivery: InactiveRuntimeNotificationDelivery()
        )
    }
}

@MainActor
private final class InactiveRuntimeNotificationPreferences:
    RuntimeNotificationPreferenceStoring {
    var isOptedIn = false
}

@MainActor
private final class InactiveRuntimeNotificationDelivery: RuntimeNotificationDelivering {
    func authorizationStatus() async -> LocalNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func deliver(_ request: RuntimeNotificationRequest) async throws {}
}

private struct NotificationEvent {
    let request: RuntimeNotificationRequest
    let route: RuntimeNotificationRoute
}

/// Kept only in the bounded in-memory route table. The semantic state retains
/// the originating run and event kind/reason without placing any of it in the
/// notification payload.
private struct RuntimeNotificationRoute {
    let projectID: String
    let semanticState: ObservedRuntimeState

    var target: AttentionNavigationTarget {
        .project(projectID: projectID, surface: .runtime)
    }
}

private enum ObservedRuntimeState: Equatable {
    case inactive
    case active(run: String?, status: RuntimeStatus)
    case ready(run: String)
    case failed(run: String, reason: String)
    case unexpectedExit(run: String, code: String)
}
