import Darwin
import Foundation
import XCTest
@testable import LocalWrapMac

final class RuntimeSupervisorTests: XCTestCase {
    func testPreparedLaunchWaitsForDurableCommitAndKeepsStableIdentity() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let marker = fixture.directory.appendingPathComponent("target-started")
        let process = try PosixProcessLauncher().prepareLaunch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf started > \(marker.path); exec /bin/sleep 10"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: fixture.directory,
            logURL: fixture.log,
            onOutput: { _ in },
            onExit: { _ in }
        )
        var committed = false
        defer {
            if committed {
                try? process.signalProcessGroup(SIGKILL)
            } else {
                process.abandonPreparedLaunch()
            }
        }

        let inspector = DarwinProcessInspector()
        let observation = try inspector.capture(
            pid: process.pid,
            commandFingerprint: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(observation.pid, process.pid)
        XCTAssertEqual(observation.processGroupID, process.pid)
        XCTAssertEqual(observation.sessionID, process.pid)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "The reviewed command must not run before its ownership record is committed."
        )

        let expectation = ProcessOwnershipExpectation(
            pid: observation.pid,
            processGroupID: observation.processGroupID,
            sessionID: observation.sessionID,
            effectiveUserID: observation.effectiveUserID,
            kernelStartTime: observation.kernelStartTime,
            observedProcessFingerprint: observation.observedProcessFingerprint
        )
        guard case .verified = inspector.inspect(expectation) else {
            return XCTFail("Prepared supervisor identity was not verifiable.")
        }

        try process.resume()
        committed = true
        let targetStarted = await waitForFile(marker)
        XCTAssertTrue(targetStarted)

        // /bin/sh has now exec'd /bin/sleep, but the LocalWrap-owned leader
        // and its fingerprint remain stable.
        guard case .verified(let verified) = inspector.inspect(expectation) else {
            return XCTFail("Supervisor identity changed after the target exec transition.")
        }
        XCTAssertEqual(verified.pid, process.pid)
        XCTAssertTrue(verified.processGroupMembers.contains(process.pid))

        guard case .verified = inspector.inspect(expectation) else {
            return XCTFail("Identity changed immediately before the stop signal.")
        }
        try process.signalProcessGroup(SIGTERM)
        let processExited = await waitForExit(process)
        XCTAssertTrue(processExited)
        XCTAssertEqual(Darwin.kill(-process.processGroupID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testAbandonedPreparedLaunchExitsWithoutStartingTargetOrSendingSignal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let marker = fixture.directory.appendingPathComponent("must-not-exist")
        let process = try PosixProcessLauncher().prepareLaunch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf unsafe > \(marker.path)"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: fixture.directory,
            logURL: fixture.log,
            onOutput: { _ in },
            onExit: { _ in }
        )

        process.abandonPreparedLaunch()

        let processExited = await waitForExit(process)
        XCTAssertTrue(processExited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(Darwin.kill(-process.processGroupID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testLauncherRejectsSymlinkedRuntimeLogDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWrapSupervisorTests-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try PosixProcessLauncher().prepareLaunch(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: root,
                logURL: linked.appendingPathComponent("run.log"),
                onOutput: { _ in },
                onExit: { _ in }
            )
        )
    }

    func testCommittedTargetDoesNotInheritRuntimeLedgerLock() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = fixture.directory.appendingPathComponent("state", isDirectory: true)
        let store = RuntimeLedgerStore(paths: RuntimeLedgerPaths(
            directory: state,
            ledger: state.appendingPathComponent("runtime-ledger.json")
        ))
        let firstLock = try store.acquireExclusiveLock()
        let process = try PosixProcessLauncher().prepareLaunch(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: fixture.directory,
            logURL: fixture.log,
            onOutput: { _ in },
            onExit: { _ in }
        )
        var committed = false
        defer {
            firstLock.unlock()
            if committed { try? process.signalProcessGroup(SIGKILL) }
            else { process.abandonPreparedLaunch() }
        }

        try process.resume()
        committed = true
        firstLock.unlock()

        let completed = DispatchSemaphore(value: 0)
        let result = RuntimeSupervisorLockResult()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let secondLock = try store.acquireExclusiveLock()
                secondLock.unlock()
            } catch {
                result.record(error)
            }
            completed.signal()
        }

        XCTAssertEqual(
            completed.wait(timeout: .now() + 1),
            .success,
            "A committed target must not retain LocalWrap's ledger transaction lock."
        )
        XCTAssertNil(result.errorDescription)
        XCTAssertTrue(process.isRunning)
    }

    private func makeFixture() throws -> (directory: URL, log: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWrapSupervisorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return (directory, directory.appendingPathComponent("run.log"))
    }

    private func waitForFile(_ url: URL) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func waitForExit(_ process: any ManagedProjectProcess) async -> Bool {
        for _ in 0..<150 {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }
}

private final class RuntimeSupervisorLockResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedErrorDescription: String?

    var errorDescription: String? { lock.withLock { storedErrorDescription } }

    func record(_ error: any Error) {
        lock.withLock { storedErrorDescription = error.localizedDescription }
    }
}
