import Darwin
import Foundation
import XCTest
@testable import LocalWrapMac

final class DarwinProcessInspectorTests: XCTestCase {
    func testCaptureReturnsOnlyRedactedStableIdentityEvidence() throws {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()
        let commandFingerprint = String(repeating: "a", count: 64)

        let observation = try makeInspector(reader: reader).capture(
            pid: 42,
            commandFingerprint: commandFingerprint
        )

        XCTAssertEqual(
            observation,
            ProcessOwnershipObservation(
                pid: 42,
                processGroupID: 42,
                sessionID: 42,
                effectiveUserID: 501,
                kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567),
                commandFingerprint: commandFingerprint,
                observedProcessFingerprint: expectedFingerprint
            )
        )
        XCTAssertEqual(reader.argumentReadCount[42], 3, "Capture must reverify live argv")
    }

    func testCaptureFailsClosedWhenExistenceIsPermissionDenied() {
        let reader = FakeDarwinProcessReader()
        reader.existenceResult = .success(.permissionDenied)

        XCTAssertThrowsError(
            try makeInspector(reader: reader).capture(
                pid: 42,
                commandFingerprint: String(repeating: "a", count: 64)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProcessOwnershipCaptureError,
                .unverifiable(.permissionDenied(.existence))
            )
        }
    }

    func testCaptureRejectsInvalidCommandFingerprintBeforeReadingPID() {
        let reader = FakeDarwinProcessReader()

        XCTAssertThrowsError(
            try makeInspector(reader: reader).capture(pid: 42, commandFingerprint: "not-a-hash")
        ) { error in
            XCTAssertEqual(error as? ProcessOwnershipCaptureError, .invalidCommandFingerprint)
        }
        XCTAssertEqual(reader.existenceReadCount, 0)
    }

    func testVerifiedOwnershipRequiresEveryIdentityFieldAndGroupMember() {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()

        let assessment = makeInspector(reader: reader).inspect(makeExpectation())

        XCTAssertEqual(
            assessment,
            .verified(
                VerifiedProcessOwnership(
                    pid: 42,
                    processGroupID: 42,
                    sessionID: 42,
                    effectiveUserID: 501,
                    kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567),
                    observedProcessFingerprint: expectedFingerprint,
                    processGroupMembers: [42, 43]
                )
            )
        )
        XCTAssertEqual(reader.argumentReadCount[42], 2, "The command must be reverified")
    }

    func testExitedPIDIsNotTreatedAsOwned() {
        let reader = FakeDarwinProcessReader()
        reader.existenceResult = .success(.exited)

        XCTAssertEqual(makeInspector(reader: reader).inspect(makeExpectation()), .exited)
        XCTAssertTrue(reader.processInfoByPID.isEmpty)
    }

    func testExitedLeaderWithRemainingGroupFailsClosed() {
        let reader = FakeDarwinProcessReader()
        reader.existenceResult = .success(.exited)
        reader.processGroupMembersResult = .success([43])

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .conflicting(.leaderMissingFromProcessGroup)
        )
    }

    func testExitedLeaderWithUninspectableGroupIsUnverifiable() {
        let reader = FakeDarwinProcessReader()
        reader.existenceResult = .success(.exited)
        reader.processGroupMembersResult = .failure(.permissionDenied(.processGroup))

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .unverifiable(.permissionDenied(.processGroup))
        )
    }

    func testExistencePermissionFailureIsUnverifiable() {
        let reader = FakeDarwinProcessReader()
        reader.existenceResult = .success(.permissionDenied)

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .unverifiable(.permissionDenied(.existence))
        )
    }

    func testPIDReuseWithDifferentKernelStartTimeIsConflicting() {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()
        reader.processInfoByPID[42] = DarwinProcessInfo(
            pid: 42,
            processGroupID: 42,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 9_999, microseconds: 1)
        )

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .conflicting(.kernelStartTime)
        )
    }

    func testMatchingPIDWithDifferentCommandIsConflicting() {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()
        reader.argumentsByPID[42] = [["node", "other.js"]]

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .conflicting(.observedProcessFingerprint)
        )
    }

    func testExecBetweenChecksFailsClosed() {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()
        reader.argumentsByPID[42] = [
            ["node", "server.js"],
            ["node", "replacement.js"]
        ]

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .conflicting(.observedProcessFingerprint)
        )
    }

    func testUnexpectedEffectiveUserInProcessGroupIsConflicting() {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()
        reader.processInfoByPID[43] = DarwinProcessInfo(
            pid: 43,
            processGroupID: 42,
            effectiveUserID: 502,
            kernelStartTime: KernelProcessStartTime(seconds: 1_235, microseconds: 0)
        )

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .conflicting(.groupMemberEffectiveUser(pid: 43))
        )
    }

    func testMismatchedGroupMemberPIDIsConflicting() {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()
        reader.processInfoByPID[43] = DarwinProcessInfo(
            pid: 99,
            processGroupID: 42,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1_235, microseconds: 0)
        )

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .conflicting(.groupMemberProcessID(pid: 43))
        )
    }

    func testMissingLeaderFromEnumeratedGroupIsConflicting() {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()
        reader.processGroupMembersResult = .success([43])

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .conflicting(.leaderMissingFromProcessGroup)
        )
    }

    func testProcessInfoPermissionFailureIsUnverifiable() {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()
        reader.processInfoErrors[42] = .permissionDenied(.processInfo)

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(makeExpectation()),
            .unverifiable(.permissionDenied(.processInfo))
        )
    }

    func testExpectationForAnotherUserFailsBeforeInspectingPID() {
        let reader = FakeDarwinProcessReader()
        reader.installVerifiedFixture()
        let expectation = ProcessOwnershipExpectation(
            pid: 42,
            processGroupID: 42,
            sessionID: 42,
            effectiveUserID: 502,
            kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567),
            observedProcessFingerprint: expectedFingerprint
        )

        XCTAssertEqual(
            makeInspector(reader: reader).inspect(expectation),
            .conflicting(.effectiveUser)
        )
        XCTAssertEqual(reader.existenceReadCount, 0)
    }

    func testKernProcArgumentsParserReadsExactlyArgcAndDiscardsEnvironment() throws {
        let payload = makeProcArgumentsPayload(
            executable: "/usr/bin/node",
            arguments: ["node", "server.js", "", "--port=3000"],
            environment: ["TOKEN=must-not-be-returned", "PATH=/usr/bin"]
        )

        let arguments = try DarwinProcessArguments.parse(payload)

        XCTAssertEqual(arguments, ["node", "server.js", "", "--port=3000"])
        XCTAssertFalse(arguments.contains { $0.contains("TOKEN") })
    }

    func testKernProcArgumentsParserRejectsTruncatedArgv() {
        let payload = makeProcArgumentsPayload(
            executable: "/usr/bin/node",
            arguments: ["node"],
            environment: []
        )
        var wrongCount: Int32 = 2
        var corrupt = payload
        withUnsafeBytes(of: &wrongCount) { bytes in
            corrupt.replaceSubrange(0..<MemoryLayout<Int32>.size, with: bytes)
        }

        XCTAssertThrowsError(try DarwinProcessArguments.parse(corrupt))
    }

    func testFingerprintPreservesArgumentBoundariesAndNeverAcceptsEnvironment() {
        let first = ProcessCommandFingerprint.make(
            executablePath: "/usr/bin/node",
            arguments: ["node", "ab", "c"]
        )
        let second = ProcessCommandFingerprint.make(
            executablePath: "/usr/bin/node",
            arguments: ["node", "a", "bc"]
        )
        let repeated = ProcessCommandFingerprint.make(
            executablePath: "/usr/bin/node",
            arguments: ["node", "ab", "c"]
        )

        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            ProcessCommandFingerprint.makeForLaunch(
                executablePath: "/usr/bin/node",
                arguments: ["server.js"]
            ),
            ProcessCommandFingerprint.make(
                executablePath: "/usr/bin/node",
                arguments: ["/usr/bin/node", "server.js"]
            )
        )
    }

    func testLaunchContractFingerprintCoversRuntimeMeaningWithoutQueryValues() throws {
        let base = ProcessCommandFingerprint.makeLaunchContract(
            executablePath: "/usr/bin/node",
            arguments: ["server.js"],
            workingDirectory: URL(fileURLWithPath: "/tmp/app", isDirectory: true),
            port: 3_000,
            readinessURL: try XCTUnwrap(URL(string: "http://localhost:3000/health?token=one"))
        )
        let queryChanged = ProcessCommandFingerprint.makeLaunchContract(
            executablePath: "/usr/bin/node",
            arguments: ["server.js"],
            workingDirectory: URL(fileURLWithPath: "/tmp/app", isDirectory: true),
            port: 3_000,
            readinessURL: try XCTUnwrap(URL(string: "http://localhost:3000/health?token=two"))
        )
        let pathChanged = ProcessCommandFingerprint.makeLaunchContract(
            executablePath: "/usr/bin/node",
            arguments: ["server.js"],
            workingDirectory: URL(fileURLWithPath: "/tmp/app", isDirectory: true),
            port: 3_000,
            readinessURL: try XCTUnwrap(URL(string: "http://localhost:3000/ready"))
        )

        XCTAssertEqual(base, queryChanged)
        XCTAssertNotEqual(base, pathChanged)
        XCTAssertEqual(base.count, 64)
    }

    func testLedgerRecordMapsOnlyPersistedIdentityEvidence() {
        let record = RuntimeLedgerRecord(
            runID: "run-1",
            projectID: "project-1",
            pid: 42,
            processGroupID: 42,
            sessionID: 42,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567),
            commandFingerprint: String(repeating: "a", count: 64),
            observedProcessFingerprint: expectedFingerprint,
            port: 3_000,
            startedAt: "2026-07-18T22:00:00Z",
            logFilename: "run-1.log"
        )

        XCTAssertEqual(ProcessOwnershipExpectation(record: record), makeExpectation())
    }

    func testSystemReaderReadsCurrentProcessArgumentsWithoutEnvironment() throws {
        let reader = DarwinSystemProcessReader()
        let pid = Darwin.getpid()
        let info = try reader.processInfo(for: pid)
        let path = try reader.executablePath(for: pid)
        let arguments = try reader.arguments(for: pid)

        XCTAssertEqual(info.pid, pid)
        XCTAssertFalse(path.isEmpty)
        XCTAssertFalse(arguments.isEmpty)
        XCTAssertEqual(
            ProcessCommandFingerprint.make(executablePath: path, arguments: arguments).count,
            64
        )
    }

    func testInspectorRejectsIdentityThatIsNotItsOwnGroupAndSessionLeader() {
        var expectation = makeExpectation()
        expectation = ProcessOwnershipExpectation(
            pid: expectation.pid,
            processGroupID: expectation.pid + 1,
            sessionID: expectation.pid,
            effectiveUserID: expectation.effectiveUserID,
            kernelStartTime: expectation.kernelStartTime,
            observedProcessFingerprint: expectation.observedProcessFingerprint
        )
        let inspector = DarwinProcessInspector(
            reader: FakeDarwinProcessReader(),
            currentEffectiveUserID: 501
        )

        XCTAssertEqual(
            inspector.inspect(expectation),
            .conflicting(.invalidExpectation("processGroupID"))
        )
    }

    private var expectedFingerprint: String {
        ProcessCommandFingerprint.make(
            executablePath: "/usr/bin/node",
            arguments: ["node", "server.js"]
        )
    }

    private func makeExpectation() -> ProcessOwnershipExpectation {
        ProcessOwnershipExpectation(
            pid: 42,
            processGroupID: 42,
            sessionID: 42,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567),
            observedProcessFingerprint: expectedFingerprint
        )
    }

    private func makeInspector(reader: FakeDarwinProcessReader) -> DarwinProcessInspector {
        DarwinProcessInspector(reader: reader, currentEffectiveUserID: 501)
    }

    private func makeProcArgumentsPayload(
        executable: String,
        arguments: [String],
        environment: [String]
    ) -> Data {
        var argumentCount = Int32(arguments.count)
        var result = Data(bytes: &argumentCount, count: MemoryLayout<Int32>.size)
        result.append(contentsOf: executable.utf8)
        result.append(0)
        result.append(contentsOf: [0, 0])
        for argument in arguments {
            result.append(contentsOf: argument.utf8)
            result.append(0)
        }
        for value in environment {
            result.append(contentsOf: value.utf8)
            result.append(0)
        }
        return result
    }
}

private final class FakeDarwinProcessReader: DarwinProcessReading, @unchecked Sendable {
    var existenceResult: Result<DarwinProcessExistence, DarwinProcessReadError> = .success(.exists)
    var processInfoByPID: [Int32: DarwinProcessInfo] = [:]
    var processInfoErrors: [Int32: DarwinProcessReadError] = [:]
    var executablePathByPID: [Int32: String] = [:]
    var argumentsByPID: [Int32: [[String]]] = [:]
    var sessionIDByPID: [Int32: Int32] = [:]
    var processGroupMembersResult: Result<[Int32], DarwinProcessReadError> = .success([])
    var argumentReadCount: [Int32: Int] = [:]
    var existenceReadCount = 0

    func installVerifiedFixture() {
        processInfoByPID[42] = DarwinProcessInfo(
            pid: 42,
            processGroupID: 42,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567)
        )
        processInfoByPID[43] = DarwinProcessInfo(
            pid: 43,
            processGroupID: 42,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1_235, microseconds: 0)
        )
        executablePathByPID[42] = "/usr/bin/node"
        argumentsByPID[42] = [["node", "server.js"]]
        sessionIDByPID = [42: 42, 43: 42]
        processGroupMembersResult = .success([43, 42])
    }

    func existence(of pid: Int32) -> Result<DarwinProcessExistence, DarwinProcessReadError> {
        existenceReadCount += 1
        return existenceResult
    }

    func processInfo(for pid: Int32) throws -> DarwinProcessInfo {
        if let error = processInfoErrors[pid] { throw error }
        guard let info = processInfoByPID[pid] else {
            throw DarwinProcessReadError.systemFailure(.processInfo, code: ENOENT)
        }
        return info
    }

    func executablePath(for pid: Int32) throws -> String {
        guard let path = executablePathByPID[pid] else {
            throw DarwinProcessReadError.systemFailure(.executablePath, code: ENOENT)
        }
        return path
    }

    func arguments(for pid: Int32) throws -> [String] {
        let index = argumentReadCount[pid, default: 0]
        argumentReadCount[pid] = index + 1
        guard let values = argumentsByPID[pid], !values.isEmpty else {
            throw DarwinProcessReadError.systemFailure(.arguments, code: ENOENT)
        }
        return values[min(index, values.count - 1)]
    }

    func sessionID(for pid: Int32) throws -> Int32 {
        guard let value = sessionIDByPID[pid] else {
            throw DarwinProcessReadError.systemFailure(.session, code: ENOENT)
        }
        return value
    }

    func processGroupMembers(for processGroupID: Int32) throws -> [Int32] {
        try processGroupMembersResult.get()
    }
}
