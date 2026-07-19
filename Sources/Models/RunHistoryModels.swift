import Foundation

enum RunHistoryState: String, Codable, CaseIterable, Equatable, Sendable {
    case prepared
    case starting
    case running
    case ready
    case unresponsive
    case stopping
    case stopped
    case failed
    case exited
    case ownershipConflict = "ownership-conflict"
    case ownershipUnverifiable = "ownership-unverifiable"
}

enum RunHistoryLifecycleEvent: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case launchRequested = "launch-requested"
    case processStarted = "process-started"
    case readinessPassed = "readiness-passed"
    case readinessTimedOut = "readiness-timed-out"
    case stopRequested = "stop-requested"
    case terminateSent = "terminate-sent"
    case killSent = "kill-sent"
    case processExited = "process-exited"
    case launchFailed = "launch-failed"
    case reconciliationStarted = "reconciliation-started"
    case reconciliationRecovered = "reconciliation-recovered"
    case reconciliationBlocked = "reconciliation-blocked"
}

struct RunHistoryTransition: Codable, Equatable, Sendable {
    let at: String
    let state: RunHistoryState
}

struct RunHistoryLifecycleEntry: Codable, Equatable, Sendable {
    let at: String
    let event: RunHistoryLifecycleEvent
}

struct RunHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    static let maximumTransitions = 32
    static let maximumLifecycleEntries = 20

    var id: String { runReference }

    let runReference: String
    let projectReference: String
    let startedAt: String
    let endedAt: String?
    let finalState: RunHistoryState
    let exitCode: Int32?
    let transitions: [RunHistoryTransition]
    let lifecycleExcerpt: [RunHistoryLifecycleEntry]
}

struct RunHistoryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumRecordCount = 100
    static let maximumRecordsPerProject = 20
    static let maximumEncodedByteCount = 256 * 1_024

    let schemaVersion: Int
    let records: [RunHistoryRecord]

    static let empty = RunHistoryDocument(
        schemaVersion: currentSchemaVersion,
        records: []
    )

    init(
        schemaVersion: Int = RunHistoryDocument.currentSchemaVersion,
        records: [RunHistoryRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}

struct RunHistoryTransitionInput: Equatable, Sendable {
    let at: String
    let state: RunHistoryState
}

struct RunHistoryLifecycleInput: Equatable, Sendable {
    let at: String
    let event: RunHistoryLifecycleEvent
}

struct RunHistoryDraft: Equatable, Sendable {
    let runID: String
    let projectID: String
    let startedAt: String
    let endedAt: String?
    let finalState: RunHistoryState
    let exitCode: Int32?
    let transitions: [RunHistoryTransitionInput]
    let lifecycleExcerpt: [RunHistoryLifecycleInput]
}

struct SupportReport: Equatable, Sendable {
    static let maximumUTF8ByteCount = 16 * 1_024

    let text: String

    var previewText: String { text }
    var copyText: String { text }
    var exportText: String { text }
    var exportData: Data { Data(text.utf8) }
}
