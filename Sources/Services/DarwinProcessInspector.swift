import CryptoKit
import Darwin
import Foundation

enum ProcessCommandFingerprint {
    private static let formatMarker = "localwrap.process-command.v1"
    private static let launchContractMarker = "localwrap.launch-contract.v1"

    /// Hashes the executable path and the complete kernel argv vector. Fields
    /// are length-prefixed so argument boundaries cannot collide.
    static func make(executablePath: String, arguments: [String]) -> String {
        var payload = Data()
        append(formatMarker, to: &payload)
        append(executablePath, to: &payload)
        for argument in arguments {
            append(argument, to: &payload)
        }
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience for launchers whose arguments omit argv[0]. Live process
    /// inspection always hashes the exact argc entries returned by the kernel.
    static func makeForLaunch(executablePath: String, arguments: [String]) -> String {
        make(executablePath: executablePath, arguments: [executablePath] + arguments)
    }

    /// A redacted digest of every saved value that changes the meaning of a
    /// launch. Query and fragment values are deliberately excluded.
    static func makeLaunchContract(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        port: Int,
        readinessURL: URL
    ) -> String {
        var payload = Data()
        append(launchContractMarker, to: &payload)
        append(executablePath, to: &payload)
        for argument in arguments { append(argument, to: &payload) }
        append(workingDirectory.standardizedFileURL.resolvingSymlinksInPath().path, to: &payload)
        append(String(port), to: &payload)
        var components = URLComponents(url: readinessURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        append(components?.string ?? "invalid-readiness-url", to: &payload)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: String, to payload: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(bytes)
    }
}

struct DarwinProcessInfo: Equatable, Sendable {
    let pid: Int32
    let processGroupID: Int32
    let effectiveUserID: UInt32
    let kernelStartTime: KernelProcessStartTime
}

enum DarwinProcessExistence: Equatable, Sendable {
    case exists
    case exited
    case permissionDenied
}

enum DarwinProcessReadError: Error, Equatable, Sendable {
    case exited
    case permissionDenied(ProcessInspectionOperation)
    case systemFailure(ProcessInspectionOperation, code: Int32)
    case malformedArguments
}

protocol DarwinProcessReading: Sendable {
    func existence(of pid: Int32) -> Result<DarwinProcessExistence, DarwinProcessReadError>
    func processInfo(for pid: Int32) throws -> DarwinProcessInfo
    func executablePath(for pid: Int32) throws -> String
    func arguments(for pid: Int32) throws -> [String]
    func sessionID(for pid: Int32) throws -> Int32
    func processGroupMembers(for processGroupID: Int32) throws -> [Int32]
}

struct DarwinProcessInspector: ProcessInspecting {
    private let reader: any DarwinProcessReading
    private let currentEffectiveUserID: UInt32

    init() {
        reader = DarwinSystemProcessReader()
        currentEffectiveUserID = Darwin.geteuid()
    }

    init(reader: any DarwinProcessReading, currentEffectiveUserID: UInt32) {
        self.reader = reader
        self.currentEffectiveUserID = currentEffectiveUserID
    }

    func capture(
        pid: Int32,
        commandFingerprint: String
    ) throws -> ProcessOwnershipObservation {
        guard pid > 0 else { throw ProcessOwnershipCaptureError.invalidPID }
        guard isSHA256(commandFingerprint) else {
            throw ProcessOwnershipCaptureError.invalidCommandFingerprint
        }
        switch reader.existence(of: pid) {
        case .success(.exited):
            throw ProcessOwnershipCaptureError.exited
        case .success(.permissionDenied):
            throw ProcessOwnershipCaptureError.unverifiable(.permissionDenied(.existence))
        case .success(.exists):
            break
        case .failure(let error):
            throw captureError(for: error)
        }

        let expectation: ProcessOwnershipExpectation
        do {
            let info = try reader.processInfo(for: pid)
            guard info.pid == pid else {
                throw ProcessOwnershipCaptureError.conflicting(.processID)
            }
            guard info.effectiveUserID == currentEffectiveUserID else {
                throw ProcessOwnershipCaptureError.conflicting(.effectiveUser)
            }
            guard info.processGroupID == pid else {
                throw ProcessOwnershipCaptureError.conflicting(.processGroup)
            }
            guard info.kernelStartTime.isValid else {
                throw ProcessOwnershipCaptureError.conflicting(.kernelStartTime)
            }
            let sessionID = try reader.sessionID(for: pid)
            guard sessionID == pid else {
                throw ProcessOwnershipCaptureError.conflicting(.session)
            }
            expectation = ProcessOwnershipExpectation(
                pid: pid,
                processGroupID: info.processGroupID,
                sessionID: sessionID,
                effectiveUserID: info.effectiveUserID,
                kernelStartTime: info.kernelStartTime,
                observedProcessFingerprint: try observedFingerprint(for: pid)
            )
        } catch let error as ProcessOwnershipCaptureError {
            throw error
        } catch let error as DarwinProcessReadError {
            throw captureError(for: error)
        } catch {
            throw ProcessOwnershipCaptureError.unverifiable(
                .systemFailure(.processInfo, code: EIO)
            )
        }

        switch inspect(expectation) {
        case .exited:
            throw ProcessOwnershipCaptureError.exited
        case .unverifiable(let uncertainty):
            throw ProcessOwnershipCaptureError.unverifiable(uncertainty)
        case .conflicting(let conflict):
            throw ProcessOwnershipCaptureError.conflicting(conflict)
        case .verified(let verified):
            return ProcessOwnershipObservation(
                pid: verified.pid,
                processGroupID: verified.processGroupID,
                sessionID: verified.sessionID,
                effectiveUserID: verified.effectiveUserID,
                kernelStartTime: verified.kernelStartTime,
                commandFingerprint: commandFingerprint.lowercased(),
                observedProcessFingerprint: verified.observedProcessFingerprint
            )
        }
    }

    func inspect(_ expectation: ProcessOwnershipExpectation) -> ProcessOwnershipAssessment {
        if let conflict = validate(expectation) {
            return .conflicting(conflict)
        }
        guard expectation.effectiveUserID == currentEffectiveUserID else {
            return .conflicting(.effectiveUser)
        }

        switch reader.existence(of: expectation.pid) {
        case .success(.exited):
            return assessMissingLeader(expectation)
        case .success(.permissionDenied):
            return .unverifiable(.permissionDenied(.existence))
        case .success(.exists):
            break
        case .failure(let error):
            return assessment(for: error)
        }

        let initialInfo: DarwinProcessInfo
        let initialSessionID: Int32
        let initialFingerprint: String
        do {
            initialInfo = try reader.processInfo(for: expectation.pid)
            if let conflict = compare(initialInfo, with: expectation) {
                return .conflicting(conflict)
            }
            initialSessionID = try reader.sessionID(for: expectation.pid)
            guard initialSessionID == expectation.sessionID else {
                return .conflicting(.session)
            }
            initialFingerprint = try observedFingerprint(for: expectation.pid)
            guard initialFingerprint == expectation.observedProcessFingerprint.lowercased() else {
                return .conflicting(.observedProcessFingerprint)
            }
        } catch let error as DarwinProcessReadError {
            return assessment(for: error)
        } catch {
            return .unverifiable(.systemFailure(.processInfo, code: EIO))
        }

        let members: [Int32]
        do {
            members = try reader.processGroupMembers(for: expectation.processGroupID)
                .filter { $0 > 0 }
                .sorted()
            guard members.contains(expectation.pid) else {
                return .conflicting(.leaderMissingFromProcessGroup)
            }
            for memberPID in members where memberPID != expectation.pid {
                do {
                    let member = try reader.processInfo(for: memberPID)
                    guard member.pid == memberPID else {
                        return .conflicting(.groupMemberProcessID(pid: memberPID))
                    }
                    guard member.effectiveUserID == expectation.effectiveUserID else {
                        return .conflicting(.groupMemberEffectiveUser(pid: memberPID))
                    }
                    guard member.processGroupID == expectation.processGroupID else {
                        return .conflicting(.groupMemberProcessGroup(pid: memberPID))
                    }
                    let memberSessionID = try reader.sessionID(for: memberPID)
                    guard memberSessionID == expectation.sessionID else {
                        return .conflicting(.groupMemberSession(pid: memberPID))
                    }
                } catch DarwinProcessReadError.exited {
                    // A child may exit between the group snapshot and its
                    // inspection. The leader is reverified below.
                    continue
                }
            }
        } catch let error as DarwinProcessReadError {
            return assessment(for: error)
        } catch {
            return .unverifiable(.systemFailure(.processGroup, code: EIO))
        }

        // Re-read immutable identity and the command after enumerating the
        // group. This makes an exec or PID-reuse race fail closed.
        do {
            let finalInfo = try reader.processInfo(for: expectation.pid)
            guard finalInfo == initialInfo else {
                return .conflicting(compare(finalInfo, with: expectation) ?? .kernelStartTime)
            }
            let finalSessionID = try reader.sessionID(for: expectation.pid)
            guard finalSessionID == initialSessionID else {
                return .conflicting(.session)
            }
            let finalFingerprint = try observedFingerprint(for: expectation.pid)
            guard finalFingerprint == initialFingerprint else {
                return .conflicting(.observedProcessFingerprint)
            }
        } catch let error as DarwinProcessReadError {
            return assessment(for: error)
        } catch {
            return .unverifiable(.systemFailure(.processInfo, code: EIO))
        }

        return .verified(
            VerifiedProcessOwnership(
                pid: expectation.pid,
                processGroupID: expectation.processGroupID,
                sessionID: expectation.sessionID,
                effectiveUserID: expectation.effectiveUserID,
                kernelStartTime: expectation.kernelStartTime,
                observedProcessFingerprint: expectation.observedProcessFingerprint.lowercased(),
                processGroupMembers: members
            )
        )
    }

    private func validate(_ expectation: ProcessOwnershipExpectation) -> ProcessOwnershipConflict? {
        guard expectation.pid > 0 else { return .invalidExpectation("pid") }
        guard expectation.processGroupID == expectation.pid else {
            return .invalidExpectation("processGroupID")
        }
        guard expectation.sessionID == expectation.pid else {
            return .invalidExpectation("sessionID")
        }
        guard expectation.kernelStartTime.isValid else {
            return .invalidExpectation("kernelStartTime")
        }
        guard isSHA256(expectation.observedProcessFingerprint) else {
            return .invalidExpectation("observedProcessFingerprint")
        }
        return nil
    }

    /// A process-group leader can exit while descendants continue running.
    /// Treat the ledger entry as exited only when the recorded group is empty;
    /// otherwise the identity is no longer strong enough to permit signalling.
    private func assessMissingLeader(
        _ expectation: ProcessOwnershipExpectation
    ) -> ProcessOwnershipAssessment {
        do {
            let members = try reader.processGroupMembers(for: expectation.processGroupID)
                .filter { $0 > 0 }
            return members.isEmpty
                ? .exited
                : .conflicting(.leaderMissingFromProcessGroup)
        } catch let error as DarwinProcessReadError {
            return assessment(for: error)
        } catch {
            return .unverifiable(.systemFailure(.processGroup, code: EIO))
        }
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (65...70).contains(scalar.value)
                || (97...102).contains(scalar.value)
        }
    }

    private func compare(
        _ observed: DarwinProcessInfo,
        with expectation: ProcessOwnershipExpectation
    ) -> ProcessOwnershipConflict? {
        guard observed.pid == expectation.pid else { return .processID }
        guard observed.effectiveUserID == expectation.effectiveUserID else {
            return .effectiveUser
        }
        guard observed.processGroupID == expectation.processGroupID else {
            return .processGroup
        }
        guard observed.kernelStartTime == expectation.kernelStartTime else {
            return .kernelStartTime
        }
        return nil
    }

    private func observedFingerprint(for pid: Int32) throws -> String {
        let executablePath = try reader.executablePath(for: pid)
        let arguments = try reader.arguments(for: pid)
        return ProcessCommandFingerprint.make(
            executablePath: executablePath,
            arguments: arguments
        )
    }

    private func assessment(for error: DarwinProcessReadError) -> ProcessOwnershipAssessment {
        switch error {
        case .exited:
            .exited
        case .permissionDenied(let operation):
            .unverifiable(.permissionDenied(operation))
        case .systemFailure(let operation, let code):
            .unverifiable(.systemFailure(operation, code: code))
        case .malformedArguments:
            .unverifiable(.malformedArguments)
        }
    }

    private func captureError(for error: DarwinProcessReadError) -> ProcessOwnershipCaptureError {
        switch assessment(for: error) {
        case .exited:
            .exited
        case .unverifiable(let uncertainty):
            .unverifiable(uncertainty)
        case .conflicting(let conflict):
            .conflicting(conflict)
        case .verified:
            .unverifiable(.systemFailure(.processInfo, code: EIO))
        }
    }
}

struct DarwinSystemProcessReader: DarwinProcessReading {
    func existence(of pid: Int32) -> Result<DarwinProcessExistence, DarwinProcessReadError> {
        if Darwin.kill(pid, 0) == 0 {
            return .success(.exists)
        }
        switch errno {
        case ESRCH:
            return .success(.exited)
        case EPERM, EACCES:
            return .success(.permissionDenied)
        default:
            return .failure(.systemFailure(.existence, code: errno))
        }
    }

    func processInfo(for pid: Int32) throws -> DarwinProcessInfo {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        errno = 0
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        guard result == expectedSize else {
            throw readError(for: .processInfo)
        }
        return DarwinProcessInfo(
            pid: Int32(bitPattern: info.pbi_pid),
            processGroupID: Int32(bitPattern: info.pbi_pgid),
            effectiveUserID: info.pbi_uid,
            kernelStartTime: KernelProcessStartTime(
                seconds: info.pbi_start_tvsec,
                microseconds: info.pbi_start_tvusec
            )
        )
    }

    func executablePath(for pid: Int32) throws -> String {
        // PROC_PIDPATHINFO_MAXSIZE is a compound C macro and is therefore not
        // imported into Swift. Its documented value is four MAXPATHLENs.
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        errno = 0
        let count = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard count > 0 else { throw readError(for: .executablePath) }
        let bytes = buffer.prefix(Int(count)).prefix { $0 != 0 }
        guard let path = String(bytes: bytes, encoding: .utf8), !path.isEmpty else {
            throw DarwinProcessReadError.systemFailure(.executablePath, code: EILSEQ)
        }
        return path
    }

    func arguments(for pid: Int32) throws -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var byteCount = 0
        errno = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, UInt32(pointer.count), nil, &byteCount, nil, 0)
        }
        guard sizeResult == 0, byteCount > MemoryLayout<Int32>.size else {
            throw readError(for: .arguments)
        }
        var buffer = [UInt8](repeating: 0, count: byteCount)
        errno = 0
        let readResult = mib.withUnsafeMutableBufferPointer { pointer in
            buffer.withUnsafeMutableBytes { bytes in
                sysctl(
                    pointer.baseAddress,
                    UInt32(pointer.count),
                    bytes.baseAddress,
                    &byteCount,
                    nil,
                    0
                )
            }
        }
        guard readResult == 0 else { throw readError(for: .arguments) }
        do {
            return try DarwinProcessArguments.parse(Data(buffer.prefix(byteCount)))
        } catch {
            throw DarwinProcessReadError.malformedArguments
        }
    }

    func sessionID(for pid: Int32) throws -> Int32 {
        errno = 0
        let sessionID = Darwin.getsid(pid)
        guard sessionID >= 0 else { throw readError(for: .session) }
        return sessionID
    }

    func processGroupMembers(for processGroupID: Int32) throws -> [Int32] {
        errno = 0
        let requiredBytes = proc_listpids(
            UInt32(PROC_PGRP_ONLY),
            UInt32(bitPattern: processGroupID),
            nil,
            0
        )
        guard requiredBytes >= 0 else { throw readError(for: .processGroup) }
        if requiredBytes == 0 {
            if errno != 0 { throw readError(for: .processGroup) }
            return []
        }

        let sparePIDCapacity = 64
        let capacity = (Int(requiredBytes) / MemoryLayout<Int32>.size) + sparePIDCapacity
        var pids = [Int32](repeating: 0, count: capacity)
        errno = 0
        let returnedBytes = pids.withUnsafeMutableBytes { bytes in
            proc_listpids(
                UInt32(PROC_PGRP_ONLY),
                UInt32(bitPattern: processGroupID),
                bytes.baseAddress,
                Int32(bytes.count)
            )
        }
        guard returnedBytes >= 0 else { throw readError(for: .processGroup) }
        if returnedBytes == 0, errno != 0 { throw readError(for: .processGroup) }
        guard returnedBytes < pids.count * MemoryLayout<Int32>.size else {
            throw DarwinProcessReadError.systemFailure(.processGroup, code: EOVERFLOW)
        }
        let count = Int(returnedBytes) / MemoryLayout<Int32>.size
        return Array(Set(pids.prefix(count).filter { $0 > 0 })).sorted()
    }

    private func readError(for operation: ProcessInspectionOperation) -> DarwinProcessReadError {
        switch errno {
        case ESRCH:
            .exited
        case EPERM, EACCES:
            .permissionDenied(operation)
        case 0:
            .systemFailure(operation, code: EIO)
        default:
            .systemFailure(operation, code: errno)
        }
    }
}

enum DarwinProcessArguments {
    static func parse(_ data: Data) throws -> [String] {
        let integerSize = MemoryLayout<Int32>.size
        guard data.count > integerSize else { throw DarwinProcessReadError.malformedArguments }

        var argumentCount: Int32 = 0
        _ = withUnsafeMutableBytes(of: &argumentCount) { destination in
            data.copyBytes(to: destination, from: 0..<integerSize)
        }
        guard argumentCount > 0, argumentCount <= 65_536 else {
            throw DarwinProcessReadError.malformedArguments
        }

        var index = integerSize
        guard let executableTerminator = data[index...].firstIndex(of: 0),
              executableTerminator > index else {
            throw DarwinProcessReadError.malformedArguments
        }
        index = executableTerminator + 1

        // KERN_PROCARGS2 pads between the executable path and argv[0]. This is
        // the only place where repeated NUL bytes are padding rather than a
        // potentially intentional empty argument.
        while index < data.endIndex, data[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        for _ in 0..<argumentCount {
            guard index < data.endIndex,
                  let terminator = data[index...].firstIndex(of: 0),
                  let argument = String(data: data[index..<terminator], encoding: .utf8) else {
                throw DarwinProcessReadError.malformedArguments
            }
            arguments.append(argument)
            index = terminator + 1
        }
        return arguments
    }
}
