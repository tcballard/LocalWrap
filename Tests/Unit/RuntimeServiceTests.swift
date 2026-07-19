import Darwin
import Foundation
import XCTest
@testable import LocalWrapMac

final class RuntimeServiceTests: XCTestCase {
    func testPosixLauncherCapturesFinalLineWithoutTrailingNewline() async throws {
        let recorder = ProcessRecorder()
        let process = try PosixProcessLauncher().launch(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["final-line"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.temporaryDirectory,
            onOutput: { line in
                Task { await recorder.record(line: line) }
            },
            onExit: { code in
                Task { await recorder.record(exitCode: code) }
            }
        )

        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            if await recorder.exitCode != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let lines = await recorder.lines
        let exitCode = await recorder.exitCode
        XCTAssertEqual(lines, ["final-line"])
        XCTAssertEqual(exitCode, 0)
    }

    func testPosixLauncherBoundsNewlineFreeOutput() async throws {
        let recorder = ProcessRecorder()
        let process = try PosixProcessLauncher().launch(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: [String(repeating: "x", count: 70_000)],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.temporaryDirectory,
            onOutput: { line in
                Task { await recorder.record(line: line) }
            },
            onExit: { code in
                Task { await recorder.record(exitCode: code) }
            }
        )

        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            if await recorder.exitCode != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let lines = await recorder.lines
        let exitCode = await recorder.exitCode
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.hasSuffix("… [output line truncated]") == true)
        XCTAssertLessThanOrEqual(lines.first?.utf8.count ?? .max, 66_000)
        XCTAssertEqual(exitCode, 0)
    }

    func testLifecycleReachesReadyAndBoundsLogs() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: true),
            doctor: makeDoctor(),
            now: { "2026-07-10T12:00:00Z" },
            isDirectory: { _ in true }
        )
        let project = makeProject()

        _ = try await service.start(project)
        for index in 0...RuntimeSnapshot.maximumLogLines {
            launcher.process?.emit("line-\(index)")
        }
        let state = await waitForLog("line-500", projectID: project.id, service: service)

        XCTAssertEqual(state.status, .ready)
        XCTAssertEqual(state.readinessMessage, "Project is ready.")
        XCTAssertEqual(state.logs.count, RuntimeSnapshot.maximumLogLines)
        XCTAssertEqual(state.logs.last, "line-500")
    }

    func testOutputCallbacksRemainOrderedAheadOfExit() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: true),
            doctor: makeDoctor(),
            isDirectory: { _ in true }
        )
        let project = makeProject()
        _ = try await service.start(project)
        let expected = (0..<100).map { "ordered-\($0)" }

        for line in expected {
            launcher.process?.emit(line)
        }
        launcher.process?.exit(code: 2)
        let state = await waitForStatus(.failed, projectID: project.id, service: service)

        XCTAssertEqual(state.logs.filter { $0.hasPrefix("ordered-") }, expected)
        XCTAssertEqual(state.logs.last, "[process exited with code 2]")
    }

    func testLegacyStopFailsClosedWithoutVerifiedOwnership() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: false),
            doctor: makeDoctor(),
            isDirectory: { _ in true }
        )
        let project = makeProject()
        _ = try await service.start(project)

        let state = await service.stop(projectID: project.id)

        XCTAssertTrue(launcher.process?.signals.isEmpty == true)
        XCTAssertEqual(state.status, .runningUnresponsive)
        XCTAssertNotNil(state.pid)
        XCTAssertEqual(state.terminalReason, .ownershipUnverifiable)
        XCTAssertEqual(state.diagnosis.status, .attention)
        XCTAssertEqual(state.diagnosis.check(.process).status, .warn)
    }

    func testUnexpectedNonzeroExitBecomesFailed() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: false),
            doctor: makeDoctor(),
            isDirectory: { _ in true }
        )
        let project = makeProject()
        _ = try await service.start(project)

        launcher.process?.exit(code: 2)
        try await Task.sleep(for: .milliseconds(50))
        let state = await service.snapshot(for: project.id)

        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.exitCode, 2)
        XCTAssertEqual(state.error, "Process exited unexpectedly with code 2.")
        XCTAssertEqual(state.terminalReason, .unexpectedExit(code: 2))
        XCTAssertEqual(state.diagnosis.status, .failed)
        XCTAssertEqual(state.diagnosis.check(.process).status, .fail)
    }

    func testUnrequestedZeroExitIsStillAnUnexpectedRuntimeFailure() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: false),
            doctor: makeDoctor(),
            isDirectory: { _ in true }
        )
        let project = makeProject()
        _ = try await service.start(project)

        launcher.process?.exit(code: 0)
        try await Task.sleep(for: .milliseconds(50))
        let state = await service.snapshot(for: project.id)

        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.terminalReason, .unexpectedExit(code: 0))
        XCTAssertEqual(state.error, "Process exited unexpectedly with code 0.")
    }

    func testReadinessTimeoutBecomesRunningUnresponsive() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: false),
            doctor: makeDoctor(),
            isDirectory: { _ in true }
        )
        let project = makeProject()

        _ = try await service.start(project)
        try await Task.sleep(for: .milliseconds(50))
        let state = await service.snapshot(for: project.id)

        XCTAssertEqual(state.status, .runningUnresponsive)
        XCTAssertTrue(state.readinessMessage?.contains("did not respond") == true)
        XCTAssertEqual(state.diagnosis.status, .attention)
        XCTAssertEqual(state.diagnosis.check(.readiness).status, .warn)
        _ = await service.stop(projectID: project.id)
    }

    func testLegacyRestartDoesNotReplaceAnUnverifiedRun() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: true),
            doctor: makeDoctor(),
            isDirectory: { _ in true }
        )
        let project = makeProject()
        _ = try await service.start(project)
        let first = try XCTUnwrap(launcher.process)

        do {
            _ = try await service.restart(project)
            XCTFail("Expected restart to fail closed")
        } catch let error as RuntimeError {
            guard case .ownershipNotVerified = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(first.signals.isEmpty)
        XCTAssertEqual(launcher.launchCount, 1)
        let restarted = await service.snapshot(for: project.id)
        XCTAssertEqual(restarted.terminalReason, .ownershipUnverifiable)
    }

    func testBundledSampleReachesReadyAndLeavesNoProcessGroup() async throws {
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples/sample-project", isDirectory: true)
        let port = try PortSuggestionService().suggest(preferred: 4_321)
        let project = Project(
            id: "sample-integration",
            name: "Sample",
            cwd: sample.path,
            command: "npm start",
            port: port,
            url: "http://localhost:\(port)",
            isSample: true,
            createdAt: "2026-07-10T12:00:00Z",
            updatedAt: "2026-07-10T12:00:00Z"
        )
        let ledgerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWrapRuntimeServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: ledgerDirectory) }
        let ledger = RuntimeLedgerStore(paths: RuntimeLedgerPaths(
            directory: ledgerDirectory,
            ledger: ledgerDirectory.appendingPathComponent("runtime-ledger.json")
        ))
        let service = RuntimeService(
            launcher: PosixProcessLauncher(),
            ledgerStore: ledger,
            processInspector: DarwinProcessInspector()
        )
        let started = try await service.start(project)
        let pid = try XCTUnwrap(started.pid)

        let ready = await waitForStatus(.ready, projectID: project.id, service: service)
        XCTAssertEqual(ready.status, .ready, ready.logs.joined(separator: "\n"))

        _ = await service.stop(projectID: project.id)
        let groupExited = await waitForProcessGroupToExit(pid)
        XCTAssertTrue(groupExited, "Process group \(pid) survived stop")
    }

    func testDoctorPreflightFailureNeverInvokesLauncher() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: true),
            doctor: makeDoctor(),
            isDirectory: { _ in true }
        )
        var project = makeProject()
        project.cwd = "/missing-project-directory"

        do {
            _ = try await service.start(project)
            XCTFail("Expected Doctor to block start")
        } catch let error as RuntimeError {
            guard case .doctorBlocked = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(launcher.launchCount, 0)
        let snapshot = await service.snapshot(for: project.id)
        XCTAssertEqual(snapshot.diagnosis.status, .failed)
    }

    func testDoctorWarningsStillLaunchAndRuntimeTransitionsUpdateChecks() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: true),
            doctor: makeDoctor(),
            isDirectory: { _ in true }
        )
        let project = makeProject()

        _ = try await service.start(project)
        let ready = await waitForStatus(.ready, projectID: project.id, service: service)

        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(ready.diagnosis.status, .ready)
        XCTAssertEqual(ready.diagnosis.check(.process).status, .pass)
        XCTAssertEqual(ready.diagnosis.check(.readiness).status, .pass)
        XCTAssertTrue(ready.diagnosis.timeline.contains { $0.message == "Readiness polling started." })
        _ = await service.stop(projectID: project.id)
    }

    func testProcessResolutionFailureUpdatesDoctorWithoutLaunching() async throws {
        let launcher = FakeProcessLauncher()
        let service = RuntimeService(
            environmentResolver: EnvironmentResolver(
                environment: { ["PATH": "/nowhere"] },
                isExecutable: { _ in false }
            ),
            launcher: launcher,
            readiness: FixedReadiness(result: true),
            doctor: makeDoctor(),
            isDirectory: { _ in true }
        )
        let project = makeProject()

        do {
            _ = try await service.start(project)
            XCTFail("Expected executable resolution to fail")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .executableNotFound("npm"))
        }
        let state = await service.snapshot(for: project.id)

        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(state.diagnosis.status, .failed)
        XCTAssertEqual(state.diagnosis.check(.process).status, .fail)
        XCTAssertEqual(state.diagnosis.check(.readiness).status, .pending)
    }

    func testStubbornLegacyProcessIsNotSignalledWithoutOwnershipEvidence() async throws {
        let launcher = StubbornProcessLauncher()
        let service = RuntimeService(
            environmentResolver: testEnvironmentResolver(),
            launcher: launcher,
            readiness: FixedReadiness(result: false),
            doctor: makeDoctor(),
            terminationWaitAttempts: 0,
            killWaitAttempts: 0,
            isDirectory: { _ in true }
        )
        let project = makeProject()
        _ = try await service.start(project)

        let state = await service.stop(projectID: project.id)

        XCTAssertTrue(launcher.process.signals.isEmpty)
        XCTAssertEqual(state.status, .runningUnresponsive)
        XCTAssertEqual(state.terminalReason, .ownershipUnverifiable)
        XCTAssertEqual(state.diagnosis.status, .attention)
        XCTAssertEqual(state.diagnosis.check(.process).status, .warn)
    }

    private func testEnvironmentResolver() -> EnvironmentResolver {
        EnvironmentResolver(
            environment: { ["PATH": "/tools"] },
            isExecutable: { $0 == "/tools/npm" }
        )
    }

    private func makeDoctor() -> ProjectDoctorService {
        ProjectDoctorService(
            portSuggester: PortSuggestionService(isAvailable: { _ in true }),
            now: { "2026-07-10T12:00:00Z" }
        )
    }

    private func makeProject() -> Project {
        Project(
            id: "project",
            name: "Project",
            cwd: FileManager.default.temporaryDirectory.path,
            command: "npm start",
            port: 3_000,
            url: "http://localhost:3000",
            createdAt: "2026-07-10T12:00:00Z",
            updatedAt: "2026-07-10T12:00:00Z"
        )
    }

    private func waitForStatus(
        _ status: RuntimeStatus,
        projectID: String,
        service: RuntimeService
    ) async -> RuntimeSnapshot {
        for _ in 0..<100 {
            let state = await service.snapshot(for: projectID)
            if state.status == status || state.status == .failed { return state }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await service.snapshot(for: projectID)
    }

    private func waitForLog(
        _ line: String,
        projectID: String,
        service: RuntimeService
    ) async -> RuntimeSnapshot {
        for _ in 0..<50 {
            let state = await service.snapshot(for: projectID)
            if state.logs.contains(line) { return state }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await service.snapshot(for: projectID)
    }

    private func waitForProcessGroupToExit(_ pid: Int32) async -> Bool {
        for _ in 0..<30 {
            errno = 0
            if Darwin.kill(-pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

private actor ProcessRecorder {
    private(set) var lines: [String] = []
    private(set) var exitCode: Int32?

    func record(line: String) {
        lines.append(line)
    }

    func record(exitCode: Int32) {
        self.exitCode = exitCode
    }
}

private struct FixedReadiness: ReadinessProbing {
    let result: Bool

    func waitUntilReady(url: URL, timeout: Duration, interval: Duration) async -> Bool {
        result
    }
}

private final class FakeProcessLauncher: ProjectProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcesses: [FakeManagedProcess] = []

    var process: FakeManagedProcess? {
        lock.withLock { storedProcesses.last }
    }

    var launchCount: Int { lock.withLock { storedProcesses.count } }

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        let process = FakeManagedProcess(onOutput: onOutput, onExit: onExit)
        lock.withLock { storedProcesses.append(process) }
        return process
    }
}

private final class FakeManagedProcess: ManagedProjectProcess, @unchecked Sendable {
    let pid: Int32 = 42
    private let lock = NSLock()
    private var running = true
    private var recordedSignals: [Int32] = []
    private let onOutput: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void

    var isRunning: Bool { lock.withLock { running } }
    var signals: [Int32] { lock.withLock { recordedSignals } }

    init(
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func signalProcessGroup(_ signal: Int32) {
        lock.withLock { recordedSignals.append(signal) }
        exit(code: 128 + signal)
    }

    func emit(_ line: String) {
        onOutput(line)
    }

    func exit(code: Int32) {
        let shouldExit = lock.withLock {
            guard running else { return false }
            running = false
            return true
        }
        if shouldExit { onExit(code) }
    }
}

private final class StubbornProcessLauncher: ProjectProcessLaunching, @unchecked Sendable {
    let process = StubbornManagedProcess()

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        process
    }
}

private final class StubbornManagedProcess: ManagedProjectProcess, @unchecked Sendable {
    let pid: Int32 = 91
    private let lock = NSLock()
    private var recordedSignals: [Int32] = []

    var isRunning: Bool { true }
    var signals: [Int32] { lock.withLock { recordedSignals } }

    func signalProcessGroup(_ signal: Int32) {
        lock.withLock { recordedSignals.append(signal) }
    }
}
