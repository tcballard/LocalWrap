import Darwin
import Foundation
import XCTest
@testable import LocalWrapMac

final class RuntimeReconciliationTests: XCTestCase {
    func testManagedStartPersistsIdentityBeforeResumingProcess() async throws {
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(events: events)
        let inspector = ManagedRuntimeInspector(events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)
        let project = makeProject()

        let state = try await service.start(project)

        let runID = try XCTUnwrap(state.runID)
        XCTAssertEqual(state.ownership, .verified(runID: runID))
        XCTAssertEqual(launcher.preparedProcess?.resumeCount, 1)
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ledger.records.first?.runID, runID)
        XCTAssertEqual(ledger.records.first?.projectID, project.id)
        XCTAssertEqual(ledger.records.first?.pid, launcher.preparedProcess?.pid)
        XCTAssertEqual(ledger.upsertedRecords.map(\.phase), [.prepared, .running])
        assertOrdered(
            [
                "launcher.prepare",
                "inspector.capture",
                "ledger.upsert",
                "inspector.inspect",
                "process.resume",
                "ledger.upsert",
            ],
            in: events.values
        )
    }

    func testCaptureFailureNeverPersistsOrResumesProcess() async {
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(events: events)
        let inspector = ManagedRuntimeInspector(events: events)
        inspector.captureError = ProcessOwnershipCaptureError.unverifiable(
            .permissionDenied(.processInfo)
        )
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        do {
            _ = try await service.start(makeProject())
            XCTFail("Expected capture to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ProcessOwnershipCaptureError,
                .unverifiable(.permissionDenied(.processInfo))
            )
        }

        XCTAssertEqual(launcher.preparedProcess?.resumeCount, 0)
        XCTAssertEqual(launcher.preparedProcess?.abandonCount, 1)
        XCTAssertTrue(launcher.preparedProcess?.signals.isEmpty == true)
        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertEqual(ledger.removedLogFilenames.count, 1)
        XCTAssertFalse(events.values.contains("ledger.upsert"))
    }

    func testLedgerFailureNeverResumesProcess() async {
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(events: events)
        ledger.upsertError = RuntimeLedgerError.writeFailed("injected write failure")
        let inspector = ManagedRuntimeInspector(inspections: [.exited], events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        do {
            _ = try await service.start(makeProject())
            XCTFail("Expected ledger persistence to fail")
        } catch {
            XCTAssertEqual(
                error as? RuntimeLedgerError,
                .writeFailed("injected write failure")
            )
        }

        XCTAssertEqual(launcher.preparedProcess?.resumeCount, 0)
        XCTAssertEqual(launcher.preparedProcess?.abandonCount, 1)
        XCTAssertTrue(launcher.preparedProcess?.signals.isEmpty == true)
        XCTAssertTrue(ledger.records.isEmpty)
        assertOrdered(
            ["launcher.prepare", "inspector.capture", "ledger.upsert", "process.abandon"],
            in: events.values
        )
        XCTAssertFalse(events.values.contains("process.resume"))
    }

    func testRunningPhaseWriteFailureDoesNotTerminateCommittedRuntime() async throws {
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(events: events)
        ledger.failUpsertCall = 2
        ledger.upsertError = RuntimeLedgerError.writeFailed("injected phase write failure")
        let inspector = ManagedRuntimeInspector(events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        let state = try await service.start(makeProject())

        XCTAssertEqual(launcher.preparedProcess?.resumeCount, 1)
        XCTAssertTrue(launcher.preparedProcess?.signals.isEmpty == true)
        XCTAssertEqual(launcher.preparedProcess?.abandonCount, 0)
        XCTAssertEqual(ledger.records.first?.phase, .prepared)
        XCTAssertEqual(ledger.upsertedRecords.map(\.phase), [.prepared])
        XCTAssertTrue(state.ownership.permitsSignalling)
        XCTAssertTrue(state.logs.contains {
            $0.contains("Runtime is active; launch phase will be reconciled later")
        })
    }

    func testExistingVerifiedRecordBlocksDuplicateStartBeforeLaunch() async throws {
        let project = makeProject()
        let record = makeRecord(project: project)
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(records: [record], events: events)
        let inspector = ManagedRuntimeInspector(events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        do {
            _ = try await service.start(project)
            XCTFail("Expected duplicate start to be blocked")
        } catch {
            XCTAssertEqual(
                error as? RuntimeError,
                .reconciliationRequired("LocalWrap already owns a recorded run for this project.")
            )
        }

        XCTAssertEqual(launcher.prepareCount, 0)
        XCTAssertEqual(ledger.records, [record])
        XCTAssertEqual(Array(events.values.prefix(2)), ["ledger.load", "inspector.inspect"])
    }

    func testCorruptLedgerBlocksStartBeforeLaunch() async {
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(events: events)
        ledger.loadError = RuntimeLedgerError.corruptLedger("injected corrupt ledger")
        let inspector = ManagedRuntimeInspector(events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        do {
            _ = try await service.start(makeProject())
            XCTFail("Expected corrupt ledger to block launch")
        } catch {
            XCTAssertEqual(
                error as? RuntimeLedgerError,
                .corruptLedger("injected corrupt ledger")
            )
        }

        XCTAssertEqual(launcher.prepareCount, 0)
        XCTAssertEqual(inspector.captureCount, 0)
        XCTAssertEqual(events.values, ["ledger.load"])
    }

    func testReconcileRemovesExitedRecordAndPrivateLog() async {
        let project = makeProject()
        let record = makeRecord(project: project)
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(records: [record], events: events)
        let inspector = ManagedRuntimeInspector(
            inspections: [.exited],
            events: events
        )
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        let report = await service.reconcile(projects: [project])
        let state = await service.snapshot(for: project.id)

        XCTAssertNil(report.ledgerError)
        XCTAssertEqual(report.items.map(\.classification), [.exited])
        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertEqual(ledger.removedLogFilenames, [record.logFilename])
        XCTAssertEqual(launcher.monitorCount, 0)
        XCTAssertEqual(state.status, .stopped)
        XCTAssertEqual(state.ownership, .none)
    }

    func testReconcileVerifiedRecordRestoresMonitoringAndOwnership() async {
        let project = makeProject()
        let record = makeRecord(project: project)
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(records: [record], events: events)
        let inspector = ManagedRuntimeInspector(events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        let report = await service.reconcile(projects: [project])
        let state = await service.snapshot(for: project.id)

        XCTAssertNil(report.ledgerError)
        XCTAssertEqual(report.items.map(\.classification), [.verifiedOwned])
        XCTAssertEqual(launcher.monitorCount, 1)
        XCTAssertEqual(launcher.monitoredProcess?.resumeCount, 0)
        XCTAssertEqual(state.runID, record.runID)
        XCTAssertEqual(state.pid, record.pid)
        XCTAssertEqual(state.ownership, .verified(runID: record.runID))
        XCTAssertEqual(ledger.records, [record])
        assertOrdered(
            ["ledger.load", "inspector.inspect", "launcher.monitor"],
            in: events.values
        )
    }

    func testReconcilePreparedRecordPromotesPhaseWithoutReplayingCommit() async {
        let project = makeProject()
        let record = makeRecord(project: project, phase: .prepared)
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(records: [record], events: events)
        let inspector = ManagedRuntimeInspector(events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        let firstReport = await service.reconcile(projects: [project])

        XCTAssertNil(firstReport.ledgerError)
        XCTAssertEqual(firstReport.items.map(\.classification), [.verifiedOwned])
        XCTAssertEqual(launcher.monitorCount, 1)
        XCTAssertEqual(launcher.monitoredProcess?.resumeCount, 0)
        XCTAssertEqual(ledger.records.first?.phase, .running)
        assertOrdered(
            [
                "ledger.load",
                "inspector.inspect",
                "launcher.monitor",
                "inspector.inspect",
                "ledger.upsert",
            ],
            in: events.values
        )

        let secondReport = await service.reconcile(projects: [project])

        XCTAssertNil(secondReport.ledgerError)
        XCTAssertEqual(secondReport.items.map(\.classification), [.verifiedOwned])
        XCTAssertEqual(launcher.monitorCount, 1)
        XCTAssertEqual(launcher.monitoredProcess?.resumeCount, 0)
        XCTAssertEqual(ledger.records.first?.phase, .running)
    }

    func testReconcileConflictPreservesRecordWithoutMonitoring() async {
        let project = makeProject()
        let record = makeRecord(project: project)
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(records: [record], events: events)
        let inspector = ManagedRuntimeInspector(
            inspections: [.conflicting(.kernelStartTime)],
            events: events
        )
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        let report = await service.reconcile(projects: [project])
        let state = await service.snapshot(for: project.id)

        XCTAssertEqual(report.items.map(\.classification), [.conflicting])
        XCTAssertEqual(launcher.monitorCount, 0)
        XCTAssertEqual(ledger.records, [record])
        XCTAssertEqual(state.status, .runningUnresponsive)
        XCTAssertEqual(
            state.ownership,
            .conflicting(runID: record.runID, reason: .identityMismatch)
        )
        XCTAssertEqual(state.terminalReason, .ownershipConflict)
    }

    func testStopReinspectsBeforeTermAndKillThenCleansOnlyAfterExit() async throws {
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(events: events)
        let inspector = ManagedRuntimeInspector(events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(
            launcher: launcher,
            ledger: ledger,
            inspector: inspector,
            terminationWaitAttempts: 0,
            killWaitAttempts: 0
        )
        let project = makeProject()
        _ = try await service.start(project)
        events.reset()
        inspector.setInspections([.verified, .verified, .verified, .exited])

        let state = await service.stop(projectID: project.id)

        XCTAssertEqual(launcher.preparedProcess?.signals, [SIGTERM, SIGKILL])
        XCTAssertEqual(state.status, .stopped)
        XCTAssertEqual(state.ownership, .none)
        XCTAssertTrue(ledger.records.isEmpty)
        assertOrdered(
            [
                "inspector.inspect",
                "process.signal.\(SIGTERM)",
                "inspector.inspect",
                "inspector.inspect",
                "process.signal.\(SIGKILL)",
                "inspector.inspect",
                "ledger.remove",
            ],
            in: events.values
        )
    }

    func testStopDoesNotKillWhenIdentityChangesAfterTermGracePeriod() async throws {
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(events: events)
        let inspector = ManagedRuntimeInspector(events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(
            launcher: launcher,
            ledger: ledger,
            inspector: inspector,
            terminationWaitAttempts: 0,
            killWaitAttempts: 0
        )
        let project = makeProject()
        _ = try await service.start(project)
        let runID = try XCTUnwrap(ledger.records.first?.runID)
        inspector.setInspections([.verified, .verified, .conflicting(.kernelStartTime)])

        let state = await service.stop(projectID: project.id)

        XCTAssertEqual(launcher.preparedProcess?.signals, [SIGTERM])
        XCTAssertEqual(
            state.ownership,
            .conflicting(runID: runID, reason: .identityMismatch)
        )
        XCTAssertEqual(state.terminalReason, .ownershipConflict)
        XCTAssertEqual(ledger.records.first?.runID, runID)
    }

    func testStopPreservesLedgerWhenLeaderExitedButGroupSurvives() async throws {
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(events: events)
        let inspector = ManagedRuntimeInspector(events: events)
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(
            launcher: launcher,
            ledger: ledger,
            inspector: inspector,
            terminationWaitAttempts: 0,
            killWaitAttempts: 0
        )
        let project = makeProject()
        _ = try await service.start(project)
        let runID = try XCTUnwrap(ledger.records.first?.runID)
        inspector.setInspections([.verified, .conflicting(.leaderMissingFromProcessGroup)])

        let state = await service.stop(projectID: project.id)

        XCTAssertEqual(launcher.preparedProcess?.signals, [SIGTERM])
        XCTAssertEqual(
            state.ownership,
            .conflicting(runID: runID, reason: .processGroupMismatch)
        )
        XCTAssertEqual(ledger.records.first?.runID, runID)
        XCTAssertTrue(ledger.removedLogFilenames.isEmpty)
    }

    func testShutdownReportBlocksTerminationForUnresolvedRecord() async {
        let project = makeProject()
        let record = makeRecord(project: project)
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(records: [record], events: events)
        let inspector = ManagedRuntimeInspector(
            inspections: [.conflicting(.kernelStartTime)],
            fallback: .conflicting(.kernelStartTime),
            events: events
        )
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)
        _ = await service.reconcile(projects: [project])

        let report = await service.stopAllWithReport()

        XCTAssertFalse(report.canTerminate)
        XCTAssertTrue(report.stoppedProjectIDs.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.projectID, project.id)
        XCTAssertEqual(report.failures.first?.runID, record.runID)
        XCTAssertEqual(ledger.records, [record])
        XCTAssertTrue(launcher.allSignals.isEmpty)
    }

    func testShutdownStopsVerifiedLedgerOnlyRecordBeforeAllowingTermination() async {
        let project = makeProject()
        let record = makeRecord(project: project)
        let events = ManagedRuntimeEventRecorder()
        let ledger = ManagedRuntimeLedger(records: [record], events: events)
        let inspector = ManagedRuntimeInspector(
            inspections: [.verified, .verified, .verified, .exited],
            events: events
        )
        let launcher = ManagedRuntimeLauncher(events: events)
        let service = makeService(launcher: launcher, ledger: ledger, inspector: inspector)

        let report = await service.stopAllWithReport()
        let state = await service.snapshot(for: project.id)

        XCTAssertTrue(report.canTerminate)
        XCTAssertEqual(report.stoppedProjectIDs, [project.id])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(launcher.monitorCount, 1)
        XCTAssertEqual(launcher.monitoredProcess?.signals, [SIGTERM])
        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertEqual(ledger.removedLogFilenames, [record.logFilename])
        XCTAssertEqual(state.status, .stopped)
        XCTAssertEqual(state.ownership, .none)
        assertOrdered(
            [
                "ledger.load",
                "inspector.inspect",
                "launcher.monitor",
                "inspector.inspect",
                "inspector.inspect",
                "process.signal.\(SIGTERM)",
                "inspector.inspect",
                "ledger.remove",
            ],
            in: events.values
        )
    }

    private func makeService(
        launcher: ManagedRuntimeLauncher,
        ledger: ManagedRuntimeLedger,
        inspector: ManagedRuntimeInspector,
        terminationWaitAttempts: Int = 0,
        killWaitAttempts: Int = 0
    ) -> RuntimeService {
        RuntimeService(
            environmentResolver: EnvironmentResolver(
                environment: { ["PATH": "/tools"] },
                isExecutable: { $0 == "/tools/npm" }
            ),
            launcher: launcher,
            ledgerStore: ledger,
            processInspector: inspector,
            readiness: ManagedRuntimeReadiness(result: true),
            doctor: ProjectDoctorService(
                portSuggester: PortSuggestionService(isAvailable: { _ in true }),
                now: { "2026-07-19T10:00:00Z" }
            ),
            now: { "2026-07-19T10:00:00Z" },
            terminationWaitAttempts: terminationWaitAttempts,
            killWaitAttempts: killWaitAttempts,
            isDirectory: { _ in true }
        )
    }

    private func makeProject() -> Project {
        Project(
            id: "managed-project",
            name: "Managed Project",
            cwd: FileManager.default.temporaryDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000",
            createdAt: "2026-07-19T09:00:00Z",
            updatedAt: "2026-07-19T09:00:00Z"
        )
    }

    private func makeRecord(
        project: Project,
        runID: String = "run-1",
        phase: RuntimeLedgerPhase = .running
    ) -> RuntimeLedgerRecord {
        let readinessURL = URL(string: project.url) ?? URL(fileURLWithPath: "/invalid")
        return RuntimeLedgerRecord(
            phase: phase,
            runID: runID,
            projectID: project.id,
            pid: ManagedRuntimeProcess.defaultPID,
            processGroupID: ManagedRuntimeProcess.defaultPID,
            sessionID: ManagedRuntimeProcess.defaultPID,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567),
            commandFingerprint: ProcessCommandFingerprint.makeLaunchContract(
                executablePath: "/tools/npm",
                arguments: ["start"],
                workingDirectory: URL(fileURLWithPath: project.cwd, isDirectory: true),
                port: project.port,
                readinessURL: readinessURL
            ),
            observedProcessFingerprint: String(repeating: "b", count: 64),
            port: project.port,
            startedAt: "2026-07-19T09:30:00Z",
            logFilename: "run-\(runID).log"
        )
    }

    private func assertOrdered(
        _ expected: [String],
        in actual: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = actual.startIndex
        for value in expected {
            guard lowerBound <= actual.endIndex,
                  let index = actual[lowerBound...].firstIndex(of: value) else {
                XCTFail(
                    "Expected \(value) after index \(lowerBound) in \(actual)",
                    file: file,
                    line: line
                )
                return
            }
            lowerBound = actual.index(after: index)
        }
    }
}

private struct ManagedRuntimeReadiness: ReadinessProbing {
    let result: Bool

    func waitUntilReady(url: URL, timeout: Duration, interval: Duration) async -> Bool {
        result
    }
}

private final class ManagedRuntimeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }

    func reset() {
        lock.withLock { storage.removeAll() }
    }
}

private final class ManagedRuntimeLedger: RuntimeLedgerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let events: ManagedRuntimeEventRecorder
    private var storedRecords: [RuntimeLedgerRecord]
    private var storedUpsertedRecords: [RuntimeLedgerRecord] = []
    private var storedRemovedLogs: [String] = []
    private var storedLoadError: (any Error)?
    private var storedUpsertError: (any Error)?
    private var storedFailUpsertCall: Int?
    private var storedUpsertCallCount = 0

    init(
        records: [RuntimeLedgerRecord] = [],
        events: ManagedRuntimeEventRecorder
    ) {
        storedRecords = records
        self.events = events
    }

    var records: [RuntimeLedgerRecord] { lock.withLock { storedRecords } }
    var upsertedRecords: [RuntimeLedgerRecord] { lock.withLock { storedUpsertedRecords } }
    var removedLogFilenames: [String] { lock.withLock { storedRemovedLogs } }

    var loadError: (any Error)? {
        get { lock.withLock { storedLoadError } }
        set { lock.withLock { storedLoadError = newValue } }
    }

    var upsertError: (any Error)? {
        get { lock.withLock { storedUpsertError } }
        set { lock.withLock { storedUpsertError = newValue } }
    }

    var failUpsertCall: Int? {
        get { lock.withLock { storedFailUpsertCall } }
        set { lock.withLock { storedFailUpsertCall = newValue } }
    }

    func load() throws -> RuntimeLedgerDocument {
        events.append("ledger.load")
        return try lock.withLock {
            if let storedLoadError { throw storedLoadError }
            return RuntimeLedgerDocument(records: storedRecords)
        }
    }

    func save(_ document: RuntimeLedgerDocument) throws -> RuntimeLedgerDocument {
        events.append("ledger.save")
        lock.withLock { storedRecords = document.records }
        return document
    }

    func upsert(_ record: RuntimeLedgerRecord) throws -> RuntimeLedgerDocument {
        events.append("ledger.upsert")
        return try lock.withLock {
            storedUpsertCallCount += 1
            if let storedUpsertError,
               storedFailUpsertCall == nil || storedFailUpsertCall == storedUpsertCallCount {
                throw storedUpsertError
            }
            storedRecords.removeAll { $0.runID == record.runID }
            storedRecords.append(record)
            storedUpsertedRecords.append(record)
            return RuntimeLedgerDocument(records: storedRecords)
        }
    }

    func remove(runID: String) throws -> RuntimeLedgerDocument {
        events.append("ledger.remove")
        return lock.withLock {
            storedRecords.removeAll { $0.runID == runID }
            return RuntimeLedgerDocument(records: storedRecords)
        }
    }

    func logURL(for filename: String) throws -> URL {
        events.append("ledger.logURL")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWrapManagedRuntimeTests", isDirectory: true)
            .appendingPathComponent(filename)
    }

    func removeLog(filename: String) throws {
        events.append("ledger.removeLog")
        lock.withLock { storedRemovedLogs.append(filename) }
    }
}

private enum ManagedInspectionInstruction {
    case exited
    case verified
    case unverifiable(ProcessInspectionUncertainty)
    case conflicting(ProcessOwnershipConflict)

    func assessment(
        for expectation: ProcessOwnershipExpectation
    ) -> ProcessOwnershipAssessment {
        switch self {
        case .exited:
            .exited
        case .verified:
            .verified(VerifiedProcessOwnership(
                pid: expectation.pid,
                processGroupID: expectation.processGroupID,
                sessionID: expectation.sessionID,
                effectiveUserID: expectation.effectiveUserID,
                kernelStartTime: expectation.kernelStartTime,
                observedProcessFingerprint: expectation.observedProcessFingerprint,
                processGroupMembers: [expectation.pid]
            ))
        case .unverifiable(let uncertainty):
            .unverifiable(uncertainty)
        case .conflicting(let conflict):
            .conflicting(conflict)
        }
    }
}

private final class ManagedRuntimeInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let events: ManagedRuntimeEventRecorder
    private var instructions: [ManagedInspectionInstruction]
    private var fallback: ManagedInspectionInstruction
    private var storedCaptureError: (any Error)?
    private var storedCaptureCount = 0

    init(
        inspections: [ManagedInspectionInstruction] = [],
        fallback: ManagedInspectionInstruction = .verified,
        events: ManagedRuntimeEventRecorder
    ) {
        instructions = inspections
        self.fallback = fallback
        self.events = events
    }

    var captureError: (any Error)? {
        get { lock.withLock { storedCaptureError } }
        set { lock.withLock { storedCaptureError = newValue } }
    }

    var captureCount: Int { lock.withLock { storedCaptureCount } }

    func setInspections(
        _ values: [ManagedInspectionInstruction],
        fallback newFallback: ManagedInspectionInstruction = .verified
    ) {
        lock.withLock {
            instructions = values
            fallback = newFallback
        }
    }

    func capture(
        pid: Int32,
        commandFingerprint: String
    ) throws -> ProcessOwnershipObservation {
        events.append("inspector.capture")
        return try lock.withLock {
            storedCaptureCount += 1
            if let storedCaptureError { throw storedCaptureError }
            return ProcessOwnershipObservation(
                pid: pid,
                processGroupID: pid,
                sessionID: pid,
                effectiveUserID: 501,
                kernelStartTime: KernelProcessStartTime(seconds: 1_234, microseconds: 567),
                commandFingerprint: commandFingerprint,
                observedProcessFingerprint: String(repeating: "b", count: 64)
            )
        }
    }

    func inspect(_ expectation: ProcessOwnershipExpectation) -> ProcessOwnershipAssessment {
        events.append("inspector.inspect")
        let instruction = lock.withLock {
            instructions.isEmpty ? fallback : instructions.removeFirst()
        }
        return instruction.assessment(for: expectation)
    }
}

private final class ManagedRuntimeLauncher: RecoverableProjectProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let events: ManagedRuntimeEventRecorder
    private var storedPreparedProcess: ManagedRuntimeProcess?
    private var storedMonitoredProcess: ManagedRuntimeProcess?
    private var storedPrepareCount = 0
    private var storedMonitorCount = 0

    init(events: ManagedRuntimeEventRecorder) {
        self.events = events
    }

    var preparedProcess: ManagedRuntimeProcess? { lock.withLock { storedPreparedProcess } }
    var monitoredProcess: ManagedRuntimeProcess? { lock.withLock { storedMonitoredProcess } }
    var prepareCount: Int { lock.withLock { storedPrepareCount } }
    var monitorCount: Int { lock.withLock { storedMonitorCount } }
    var allSignals: [Int32] {
        (preparedProcess?.signals ?? []) + (monitoredProcess?.signals ?? [])
    }

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-legacy-runtime.log")
        let process = try prepareLaunch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            logURL: logURL,
            onOutput: onOutput,
            onExit: onExit
        )
        try process.resume()
        return process
    }

    func prepareLaunch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        logURL: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        events.append("launcher.prepare")
        let process = ManagedRuntimeProcess(logURL: logURL, events: events)
        lock.withLock {
            storedPrepareCount += 1
            storedPreparedProcess = process
        }
        return process
    }

    func monitorExisting(
        pid: Int32,
        processGroupID: Int32,
        logURL: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        events.append("launcher.monitor")
        let process = ManagedRuntimeProcess(
            pid: pid,
            processGroupID: processGroupID,
            logURL: logURL,
            events: events
        )
        lock.withLock {
            storedMonitorCount += 1
            storedMonitoredProcess = process
        }
        return process
    }
}

private final class ManagedRuntimeProcess: ManagedProjectProcess, @unchecked Sendable {
    static let defaultPID: Int32 = 7_001

    let pid: Int32
    let processGroupID: Int32
    let logURL: URL?

    private let lock = NSLock()
    private let events: ManagedRuntimeEventRecorder
    private var running = true
    private var storedResumeCount = 0
    private var storedAbandonCount = 0
    private var storedSignals: [Int32] = []

    init(
        pid: Int32 = ManagedRuntimeProcess.defaultPID,
        processGroupID: Int32 = ManagedRuntimeProcess.defaultPID,
        logURL: URL,
        events: ManagedRuntimeEventRecorder
    ) {
        self.pid = pid
        self.processGroupID = processGroupID
        self.logURL = logURL
        self.events = events
    }

    var isRunning: Bool { lock.withLock { running } }
    var resumeCount: Int { lock.withLock { storedResumeCount } }
    var abandonCount: Int { lock.withLock { storedAbandonCount } }
    var signals: [Int32] { lock.withLock { storedSignals } }

    func resume() throws {
        events.append("process.resume")
        lock.withLock { storedResumeCount += 1 }
    }

    func abandonPreparedLaunch() {
        events.append("process.abandon")
        lock.withLock {
            storedAbandonCount += 1
            running = false
        }
    }

    func signalProcessGroup(_ signal: Int32) throws {
        events.append("process.signal.\(signal)")
        lock.withLock {
            storedSignals.append(signal)
            if signal == SIGKILL { running = false }
        }
    }
}
