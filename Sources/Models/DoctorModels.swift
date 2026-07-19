import Foundation

enum DoctorStatus: String, Equatable, Sendable {
    case idle
    case checking
    case starting
    case waiting
    case ready
    case attention
    case failed
    case stopped
}

enum DoctorCheckStatus: String, Equatable, Sendable {
    case pending
    case running
    case pass
    case warn
    case fail
}

enum DoctorTimelineEventStatus: String, Equatable, Sendable {
    case info
    case pass
    case warn
    case fail
}

enum DoctorCheckID: String, CaseIterable, Equatable, Sendable {
    case directory
    case command
    case dependencies
    case port
    case url
    case process
    case readiness

    var label: String {
        switch self {
        case .directory: "Directory"
        case .command: "Command"
        case .dependencies: "Dependencies"
        case .port: "Port"
        case .url: "URL"
        case .process: "Process"
        case .readiness: "Readiness"
        }
    }
}

enum DoctorActionID: String, CaseIterable, Equatable, Sendable {
    case findFreePort = "use-free-port"
    case syncURL = "sync-url-to-port"
    case revealFolder = "reveal-directory"
    case copyReport = "copy-report"
    case revealCommand = "reveal-command"

    var label: String {
        switch self {
        case .findFreePort: "Find Free Port"
        case .syncURL: "Sync URL"
        case .revealFolder: "Reveal Folder"
        case .copyReport: "Copy Redacted Report"
        case .revealCommand: "Reveal Command"
        }
    }

    var mutatesProject: Bool {
        self == .findFreePort || self == .syncURL
    }

    static let useFreePort = DoctorActionID.findFreePort
    static let syncURLToPort = DoctorActionID.syncURL
    static let revealDirectory = DoctorActionID.revealFolder
}

enum ProjectField: String, Equatable, Hashable, Sendable {
    case name
    case cwd
    case command
    case port
    case url
    case dependencies
}

enum ProjectValidationSeverity: String, Equatable, Sendable {
    case error
    case warning
}

struct ProjectFieldValidation: Equatable, Sendable {
    let field: ProjectField
    let code: String
    let message: String
    let severity: ProjectValidationSeverity
}

struct ProjectValidation: Equatable, Sendable {
    var messages: [ProjectFieldValidation] = []

    var errors: [ProjectFieldValidation] {
        messages.filter { $0.severity == .error }
    }

    var warnings: [ProjectFieldValidation] {
        messages.filter { $0.severity == .warning }
    }

    var isValid: Bool { errors.isEmpty }

    func message(for field: ProjectField) -> ProjectFieldValidation? {
        messages.first { $0.field == field }
    }
}

struct DoctorCheck: Equatable, Sendable, Identifiable {
    let id: DoctorCheckID
    var status: DoctorCheckStatus
    var message: String
    var actions: [DoctorActionID]

    var label: String { id.label }
}

struct DoctorTimelineEvent: Equatable, Sendable, Identifiable {
    let id: String
    let at: String
    let status: DoctorTimelineEventStatus
    let message: String

    init(at: String, status: DoctorTimelineEventStatus, message: String) {
        id = "\(at)|\(status.rawValue)|\(message)"
        self.at = at
        self.status = status
        self.message = message
    }
}

struct ProjectDiagnosis: Equatable, Sendable {
    static let maximumTimelineEvents = 25

    var status: DoctorStatus
    var summary: String
    var updatedAt: String
    var checks: [DoctorCheck]
    var timeline: [DoctorTimelineEvent]
    var validation: ProjectValidation

    static func notChecked(now: String = "") -> ProjectDiagnosis {
        ProjectDiagnosis(
            status: .idle,
            summary: "Project Doctor has not checked this project yet.",
            updatedAt: now,
            checks: DoctorCheckID.allCases.map {
                DoctorCheck(id: $0, status: .pending, message: "Not checked yet.", actions: [])
            },
            timeline: [],
            validation: ProjectValidation()
        )
    }

    var hasConfigurationCheck: Bool {
        checks.first(where: { $0.id == .directory })?.status != .pending
    }

    var actions: [DoctorActionID] {
        var seen = Set<String>()
        return checks.flatMap(\.actions).filter { seen.insert($0.rawValue).inserted }
    }

    func check(_ id: DoctorCheckID) -> DoctorCheck {
        checks.first { $0.id == id }
            ?? DoctorCheck(id: id, status: .pending, message: "Not checked yet.", actions: [])
    }

    mutating func setCheck(
        _ id: DoctorCheckID,
        status: DoctorCheckStatus,
        message: String,
        actions: [DoctorActionID] = []
    ) {
        guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[index].status = status
        checks[index].message = message
        checks[index].actions = actions
    }

    mutating func addTimeline(
        _ message: String,
        status: DoctorTimelineEventStatus,
        at: String
    ) {
        timeline.append(DoctorTimelineEvent(at: at, status: status, message: message))
        if timeline.count > Self.maximumTimelineEvents {
            timeline.removeFirst(timeline.count - Self.maximumTimelineEvents)
        }
        updatedAt = at
    }
}

/// One immutable, redacted artifact shared by the preview and clipboard paths.
/// Keeping both views on the same value prevents a later diagnosis refresh from
/// changing what leaves LocalWrap after the user has reviewed it.
struct DoctorReport: Equatable, Sendable {
    let text: String

    var previewText: String { text }
    var copyText: String { text }
}

enum DoctorError: Error, Equatable, LocalizedError {
    case unknownAction(String)
    case invalidAvailablePort
    case activeProject
    case dirtyProject
    case reportPreviewRequired

    var errorDescription: String? {
        switch self {
        case .unknownAction(let action): "Unknown Project Doctor action: \(action)"
        case .invalidAvailablePort: "Project Doctor could not find a valid available port."
        case .activeProject: "Stop the project before applying a saved Doctor fix."
        case .dirtyProject: "Save or discard your edits before applying a saved Doctor fix."
        case .reportPreviewRequired:
            "Preview the exact redacted report before copying it."
        }
    }
}
