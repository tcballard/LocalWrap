import Foundation

struct KernelProcessStartTime: Codable, Equatable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64
}

enum RuntimeLedgerPhase: String, Codable, Equatable, Sendable {
    case prepared
    case running
}

struct RuntimeLedgerRecord: Codable, Equatable, Identifiable, Sendable {
    static let maximumIdentifierByteCount = 128
    static let maximumTimestampByteCount = 64
    static let maximumLogFilenameByteCount = 255

    var id: String { runID }

    var phase: RuntimeLedgerPhase = .running
    let runID: String
    let projectID: String
    let pid: Int32
    let processGroupID: Int32
    let sessionID: Int32
    let effectiveUserID: UInt32
    let kernelStartTime: KernelProcessStartTime
    let commandFingerprint: String
    let observedProcessFingerprint: String
    let port: Int
    let startedAt: String
    let logFilename: String
}

struct RuntimeLedgerDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumRecordCount = 128
    static let maximumEncodedByteCount = 256 * 1_024

    let schemaVersion: Int
    let records: [RuntimeLedgerRecord]

    static let empty = RuntimeLedgerDocument(
        schemaVersion: currentSchemaVersion,
        records: []
    )

    init(
        schemaVersion: Int = RuntimeLedgerDocument.currentSchemaVersion,
        records: [RuntimeLedgerRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}
