import Foundation

extension KernelProcessStartTime {
    var isValid: Bool {
        seconds > 0 && microseconds < 1_000_000
    }
}

/// Identity evidence captured when LocalWrap first observes a launched
/// process. Reconciliation must reproduce every field before treating the
/// process as owned.
struct ProcessOwnershipExpectation: Equatable, Sendable {
    let pid: Int32
    let processGroupID: Int32
    let sessionID: Int32
    let effectiveUserID: UInt32
    let kernelStartTime: KernelProcessStartTime
    let observedProcessFingerprint: String

    init(record: RuntimeLedgerRecord) {
        pid = record.pid
        processGroupID = record.processGroupID
        sessionID = record.sessionID
        effectiveUserID = record.effectiveUserID
        kernelStartTime = record.kernelStartTime
        observedProcessFingerprint = record.observedProcessFingerprint
    }

    init(
        pid: Int32,
        processGroupID: Int32,
        sessionID: Int32,
        effectiveUserID: UInt32,
        kernelStartTime: KernelProcessStartTime,
        observedProcessFingerprint: String
    ) {
        self.pid = pid
        self.processGroupID = processGroupID
        self.sessionID = sessionID
        self.effectiveUserID = effectiveUserID
        self.kernelStartTime = kernelStartTime
        self.observedProcessFingerprint = observedProcessFingerprint
    }
}

enum ProcessInspectionOperation: String, Equatable, Sendable {
    case existence
    case processInfo
    case executablePath
    case arguments
    case session
    case processGroup
}

enum ProcessInspectionUncertainty: Equatable, Sendable {
    case permissionDenied(ProcessInspectionOperation)
    case systemFailure(ProcessInspectionOperation, code: Int32)
    case malformedArguments
}

enum ProcessOwnershipConflict: Equatable, Sendable {
    case invalidExpectation(String)
    case effectiveUser
    case processID
    case processGroup
    case session
    case kernelStartTime
    case observedProcessFingerprint
    case leaderMissingFromProcessGroup
    case groupMemberProcessID(pid: Int32)
    case groupMemberEffectiveUser(pid: Int32)
    case groupMemberProcessGroup(pid: Int32)
    case groupMemberSession(pid: Int32)
}

struct VerifiedProcessOwnership: Equatable, Sendable {
    let pid: Int32
    let processGroupID: Int32
    let sessionID: Int32
    let effectiveUserID: UInt32
    let kernelStartTime: KernelProcessStartTime
    let observedProcessFingerprint: String
    let processGroupMembers: [Int32]
}

/// Redacted identity evidence captured for a newly launched process. Raw argv
/// is deliberately reduced to a fingerprint before this value leaves the
/// inspector.
struct ProcessOwnershipObservation: Equatable, Sendable {
    let pid: Int32
    let processGroupID: Int32
    let sessionID: Int32
    let effectiveUserID: UInt32
    let kernelStartTime: KernelProcessStartTime
    let commandFingerprint: String
    let observedProcessFingerprint: String
}

enum ProcessOwnershipCaptureError: Error, Equatable, Sendable {
    case exited
    case invalidPID
    case invalidCommandFingerprint
    case unverifiable(ProcessInspectionUncertainty)
    case conflicting(ProcessOwnershipConflict)
}

enum ProcessOwnershipAssessment: Equatable, Sendable {
    case exited
    case verified(VerifiedProcessOwnership)
    case unverifiable(ProcessInspectionUncertainty)
    case conflicting(ProcessOwnershipConflict)
}

protocol ProcessInspecting: Sendable {
    func capture(pid: Int32, commandFingerprint: String) throws -> ProcessOwnershipObservation
    func inspect(_ expectation: ProcessOwnershipExpectation) -> ProcessOwnershipAssessment
}
