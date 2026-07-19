import Darwin
import Dispatch
import Foundation
import XCTest
@testable import LocalWrapMac

final class RuntimeLedgerStoreTests: XCTestCase {
    private var root: URL!
    private var paths: RuntimeLedgerPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWrapLedgerTests-\(UUID().uuidString)", isDirectory: true)
        paths = RuntimeLedgerPaths(
            directory: root.appendingPathComponent("state", isDirectory: true),
            ledger: root.appendingPathComponent("state/runtime-ledger.json")
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testMissingLedgerLoadsEmptyWithoutCreatingState() throws {
        let document = try makeStore().load()

        XCTAssertEqual(document, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.path))
    }

    func testVersionedLedgerRoundTripsAllProcessIdentityFields() throws {
        let record = makeRecord(index: 7)
        let saved = try makeStore().save(RuntimeLedgerDocument(records: [record]))
        let loaded = try makeStore().load()

        XCTAssertEqual(saved, RuntimeLedgerDocument(records: [record]))
        XCTAssertEqual(loaded, saved)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.ledger)) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records[0]["runID"] as? String, "run-7")
        XCTAssertEqual(records[0]["phase"] as? String, "running")
        XCTAssertEqual(records[0]["processGroupID"] as? Int, 1_007)
        XCTAssertEqual(records[0]["sessionID"] as? Int, 1_007)
        XCTAssertEqual(records[0]["effectiveUserID"] as? Int, 501)
    }

    func testEncodedLedgerHasNoCommandOrEnvironmentPlaintextFields() throws {
        _ = try makeStore().save(RuntimeLedgerDocument(records: [makeRecord(index: 1)]))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.ledger)) as? [String: Any]
        )
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let keys = Set(records[0].keys)
        XCTAssertFalse(keys.contains("command"))
        XCTAssertFalse(keys.contains("arguments"))
        XCTAssertFalse(keys.contains("environment"))
        XCTAssertFalse(keys.contains("cwd"))
        XCTAssertFalse(keys.contains("headers"))
        XCTAssertFalse(keys.contains("cookies"))
        XCTAssertEqual(
            keys,
            [
                "phase", "runID", "projectID", "pid", "processGroupID", "sessionID", "effectiveUserID",
                "kernelStartTime", "commandFingerprint", "observedProcessFingerprint", "port",
                "startedAt", "logFilename",
            ]
        )
    }

    func testCorruptAndUnknownFieldLedgersFailClosed() throws {
        try install(Data("{not-json".utf8))
        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(
                error as? RuntimeLedgerError,
                .corruptLedger("Runtime ledger is not valid schema-versioned JSON.")
            )
        }

        let secretBearing = """
        {
          "schemaVersion": 1,
          "records": [{
            "phase": "running", "runID": "run-1", "projectID": "project-1", "pid": 1001,
            "processGroupID": 2001, "sessionID": 3001, "effectiveUserID": 501,
            "kernelStartTime": {"seconds": 10001, "microseconds": 1},
            "commandFingerprint": "\(String(repeating: "a", count: 64))",
            "observedProcessFingerprint": "\(String(repeating: "b", count: 64))",
            "port": 4001, "startedAt": "2026-07-18T10:00:01Z",
            "logFilename": "run-1.log", "environment": {"TOKEN": "secret"}
          }]
        }
        """
        try Data(secretBearing.utf8).write(to: paths.ledger)
        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(
                error as? RuntimeLedgerError,
                .corruptLedger("Runtime ledger is not valid schema-versioned JSON.")
            )
        }
    }

    func testUnsupportedSchemaFailsClosedWithVersion() throws {
        try install(Data(#"{"schemaVersion":99,"records":[]}"#.utf8))

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(error as? RuntimeLedgerError, .unsupportedSchema(99))
        }
    }

    func testOversizedLoadedLedgerFailsClosed() throws {
        let oversized = RuntimeLedgerDocument(
            records: (0...RuntimeLedgerDocument.maximumRecordCount).map {
                makeRecord(index: $0)
            }
        )
        let encoder = JSONEncoder()
        try install(encoder.encode(oversized))

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(
                error as? RuntimeLedgerError,
                .tooManyRecords(RuntimeLedgerDocument.maximumRecordCount + 1)
            )
        }
    }

    func testLedgerExceedingMaximumByteCountFailsBeforeDecoding() throws {
        let byteCount = RuntimeLedgerDocument.maximumEncodedByteCount + 1
        try install(Data(repeating: 0x20, count: byteCount))

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(
                error as? RuntimeLedgerError,
                .ledgerTooLarge(actualByteCount: byteCount)
            )
        }
    }

    func testSaveFailsClosedRatherThanEvictingAnActiveOwnershipRecord() throws {
        let records = (0..<140).map { makeRecord(index: $0) }

        XCTAssertThrowsError(
            try makeStore().save(RuntimeLedgerDocument(records: records))
        ) { error in
            XCTAssertEqual(error as? RuntimeLedgerError, .tooManyRecords(records.count))
        }
        XCTAssertEqual(try makeStore().load(), .empty)
    }

    func testUpsertAtCapacityFailsClosedWithoutEvictingOldestRecord() throws {
        let store = makeStore()
        let existing = (0..<RuntimeLedgerDocument.maximumRecordCount).map {
            makeRecord(index: $0)
        }
        _ = try store.save(RuntimeLedgerDocument(records: existing))

        XCTAssertThrowsError(try store.upsert(makeRecord(index: 999))) { error in
            XCTAssertEqual(
                error as? RuntimeLedgerError,
                .tooManyRecords(RuntimeLedgerDocument.maximumRecordCount + 1)
            )
        }
        XCTAssertEqual(try store.load().records, existing)
    }

    func testUpsertReplacesRunInPlaceOfDuplicateAndMovesItToNewest() throws {
        let store = makeStore()
        _ = try store.save(RuntimeLedgerDocument(records: [makeRecord(index: 1), makeRecord(index: 2)]))
        let replacement = RuntimeLedgerRecord(
            runID: "run-1",
            projectID: "project-replacement",
            pid: 9_001,
            processGroupID: 9_001,
            sessionID: 9_001,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 20_001, microseconds: 10),
            commandFingerprint: String(repeating: "c", count: 64),
            observedProcessFingerprint: String(repeating: "d", count: 64),
            port: 5_001,
            startedAt: "2026-07-18T12:00:00Z",
            logFilename: "run-1-replacement.log"
        )

        let saved = try store.upsert(replacement)

        XCTAssertEqual(saved.records.map(\.runID), ["run-2", "run-1"])
        XCTAssertEqual(saved.records.last, replacement)
    }

    func testAtomicReplacementFailurePreservesPreviousLedger() throws {
        let localStore = makeStore()
        _ = try localStore.save(RuntimeLedgerDocument(records: [makeRecord(index: 1)]))
        let original = try Data(contentsOf: paths.ledger)
        let failing = FailingRuntimeLedgerFileSystem(failingDestination: paths.ledger)
        let store = makeStore(fileSystem: failing)

        XCTAssertThrowsError(
            try store.save(RuntimeLedgerDocument(records: [makeRecord(index: 2)]))
        ) { error in
            guard case .writeFailed = error as? RuntimeLedgerError else {
                return XCTFail("Expected a typed write failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: paths.ledger), original)
        XCTAssertEqual(try localStore.load().records.map(\.runID), ["run-1"])
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: paths.directory.path
        ).filter { $0.hasPrefix(".runtime-ledger-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testDirectorySyncFailureReportsCommittedButUnconfirmedDurability() throws {
        let localStore = makeStore()
        _ = try localStore.save(RuntimeLedgerDocument(records: [makeRecord(index: 1)]))
        let store = makeStore(fileSystem: DirectorySyncFailingRuntimeLedgerFileSystem())

        XCTAssertThrowsError(
            try store.save(RuntimeLedgerDocument(records: [makeRecord(index: 2)]))
        ) { error in
            XCTAssertEqual(error as? RuntimeLedgerError, .durabilityUncertain)
        }

        XCTAssertEqual(try localStore.load().records.map(\.runID), ["run-2"])
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: paths.directory.path
        ).filter { $0.hasPrefix(".runtime-ledger-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testStagingFileIsWrittenBesideDestinationBeforeAtomicReplace() throws {
        let spy = SpyRuntimeLedgerFileSystem()
        let store = makeStore(fileSystem: spy)

        _ = try store.save(RuntimeLedgerDocument(records: [makeRecord(index: 1)]))

        XCTAssertEqual(spy.directoryPermissions, 0o700)
        XCTAssertEqual(spy.filePermissions, 0o600)
        XCTAssertEqual(spy.stagingURL?.deletingLastPathComponent(), paths.directory)
        XCTAssertEqual(spy.replacementDestination, paths.ledger)
        XCTAssertEqual(spy.replacementSource, spy.stagingURL)
        XCTAssertEqual(spy.syncedDirectory, paths.directory)
    }

    func testRepeatedSavesProduceByteIdenticalLedgerData() throws {
        let store = makeStore()
        let document = RuntimeLedgerDocument(records: [makeRecord(index: 2), makeRecord(index: 1)])

        _ = try store.save(document)
        let first = try Data(contentsOf: paths.ledger)
        _ = try store.save(document)
        let second = try Data(contentsOf: paths.ledger)

        XCTAssertEqual(second, first)
    }

    func testLiveFilesystemUsesOwnerOnlyDirectoryAndFilePermissions() throws {
        _ = try makeStore().save(RuntimeLedgerDocument(records: [makeRecord(index: 1)]))

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: paths.directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: paths.ledger.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLoadRejectsLedgerSymlinkWithoutFollowingIt() throws {
        let target = root.appendingPathComponent("attacker-controlled-ledger.json")
        try install(JSONEncoder().encode(RuntimeLedgerDocument(records: [makeRecord(index: 1)])))
        try FileManager.default.moveItem(at: paths.ledger, to: target)
        try FileManager.default.createSymbolicLink(at: paths.ledger, withDestinationURL: target)

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(error as? RuntimeLedgerError, .insecureLedger)
        }
    }

    func testLoadRejectsSymlinkedLedgerDirectory() throws {
        let realDirectory = root.appendingPathComponent("real-state", isDirectory: true)
        let realLedger = realDirectory.appendingPathComponent("runtime-ledger.json")
        let realPaths = RuntimeLedgerPaths(directory: realDirectory, ledger: realLedger)
        _ = try RuntimeLedgerStore(paths: realPaths).save(
            RuntimeLedgerDocument(records: [makeRecord(index: 1)])
        )
        try FileManager.default.createSymbolicLink(
            at: paths.directory,
            withDestinationURL: realDirectory
        )

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(error as? RuntimeLedgerError, .insecureLedger)
        }
    }

    func testLoadRejectsNonRegularLedgerAndNonPrivateModes() throws {
        try FileManager.default.createDirectory(
            at: paths.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.createDirectory(
            at: paths.ledger,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(error as? RuntimeLedgerError, .insecureLedger)
        }

        try FileManager.default.removeItem(at: paths.ledger)
        try install(JSONEncoder().encode(RuntimeLedgerDocument(records: [makeRecord(index: 1)])))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: paths.ledger.path
        )

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(error as? RuntimeLedgerError, .insecureLedger)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: paths.ledger.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o750)],
            ofItemAtPath: paths.directory.path
        )

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(error as? RuntimeLedgerError, .insecureLedger)
        }
    }

    func testLoadRejectsLedgerNotOwnedByExpectedEffectiveUser() throws {
        try install(JSONEncoder().encode(RuntimeLedgerDocument(records: [makeRecord(index: 1)])))
        let foreignOwnerFileSystem = LocalRuntimeLedgerFileSystem(
            effectiveUserID: { geteuid() &+ 1 }
        )

        XCTAssertThrowsError(try makeStore(fileSystem: foreignOwnerFileSystem).load()) { error in
            XCTAssertEqual(error as? RuntimeLedgerError, .insecureLedger)
        }
    }

    func testExclusiveLockSerializesSeparateStoreInstances() throws {
        let firstStore = makeStore()
        let secondStore = makeStore()
        let firstLock = try firstStore.acquireExclusiveLock()
        defer { firstLock.unlock() }

        let attempted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let result = RuntimeLedgerLockAttemptResult()
        DispatchQueue.global(qos: .userInitiated).async {
            attempted.signal()
            do {
                let secondLock = try secondStore.acquireExclusiveLock()
                secondLock.unlock()
            } catch {
                result.record(error)
            }
            completed.signal()
        }

        XCTAssertEqual(attempted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            completed.wait(timeout: .now() + .milliseconds(100)),
            .timedOut,
            "A second store must not enter the ledger transaction while the first lock is held."
        )

        firstLock.unlock()

        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertNil(result.errorDescription)
    }

    func testPlaintextFingerprintAndLogPathAreRejectedBeforeWriting() throws {
        let unsafeFingerprint = RuntimeLedgerRecord(
            runID: "unsafe",
            projectID: "project",
            pid: 1,
            processGroupID: 1,
            sessionID: 1,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1, microseconds: 0),
            commandFingerprint: "npm run dev --token secret",
            observedProcessFingerprint: String(repeating: "b", count: 64),
            port: 3_000,
            startedAt: "2026-07-18T10:00:00Z",
            logFilename: "../secret.log"
        )

        XCTAssertThrowsError(
            try makeStore().save(RuntimeLedgerDocument(records: [unsafeFingerprint]))
        ) { error in
            guard case .invalidRecord = error as? RuntimeLedgerError else {
                return XCTFail("Expected invalid record, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.ledger.path))
    }

    func testBoundedTextFieldsRejectOversizedAndMultilineValues() throws {
        let invalidRecords = [
            makeRecord(
                index: 1,
                runID: String(repeating: "r", count: RuntimeLedgerRecord.maximumIdentifierByteCount + 1)
            ),
            makeRecord(
                index: 2,
                projectID: String(
                    repeating: "é",
                    count: (RuntimeLedgerRecord.maximumIdentifierByteCount / 2) + 1
                )
            ),
            makeRecord(
                index: 3,
                startedAt: String(
                    repeating: "t",
                    count: RuntimeLedgerRecord.maximumTimestampByteCount + 1
                )
            ),
            makeRecord(
                index: 4,
                logFilename: String(
                    repeating: "l",
                    count: RuntimeLedgerRecord.maximumLogFilenameByteCount + 1
                )
            ),
            makeRecord(index: 5, runID: "run-5\nsecret"),
        ]

        for record in invalidRecords {
            XCTAssertThrowsError(
                try makeStore().save(RuntimeLedgerDocument(records: [record]))
            ) { error in
                guard case .invalidRecord = error as? RuntimeLedgerError else {
                    return XCTFail("Expected invalid record, got \(error)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.ledger.path))
    }

    func testDuplicateProjectRecordsAndInvalidIdentityValuesFailClosed() throws {
        let first = makeRecord(index: 1)
        let duplicate = RuntimeLedgerRecord(
            runID: "another-run",
            projectID: first.projectID,
            pid: 10,
            processGroupID: 10,
            sessionID: 10,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 1, microseconds: 0),
            commandFingerprint: String(repeating: "a", count: 64),
            observedProcessFingerprint: String(repeating: "b", count: 64),
            port: 3_000,
            startedAt: "2026-07-18T10:00:00Z",
            logFilename: "another-run.log"
        )

        XCTAssertThrowsError(
            try makeStore().save(RuntimeLedgerDocument(records: [first, duplicate]))
        )

        let invalidStart = RuntimeLedgerRecord(
            runID: "invalid-start",
            projectID: "invalid-start",
            pid: 11,
            processGroupID: 11,
            sessionID: 11,
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(seconds: 0, microseconds: 0),
            commandFingerprint: String(repeating: "a", count: 64),
            observedProcessFingerprint: String(repeating: "b", count: 64),
            port: 999,
            startedAt: "2026-07-18T10:00:00Z",
            logFilename: "invalid-start.log"
        )
        XCTAssertThrowsError(
            try makeStore().save(RuntimeLedgerDocument(records: [invalidStart]))
        )
    }

    func testLogURLsStayInsidePrivateRuntimeLogDirectory() throws {
        let store = makeStore()

        XCTAssertEqual(
            try store.logURL(for: "run-1.log"),
            paths.logs.appendingPathComponent("run-1.log")
        )
        XCTAssertThrowsError(try store.logURL(for: "../run-1.log")) { error in
            XCTAssertEqual(
                error as? RuntimeLedgerError,
                .invalidLogFilename("../run-1.log")
            )
        }
    }

    func testRemoveLogDeletesOnlyPrivateRegularFile() throws {
        try FileManager.default.createDirectory(
            at: paths.logs,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: paths.logs.path
        )
        let log = paths.logs.appendingPathComponent("run-1.log")
        try Data("safe".utf8).write(to: log)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: log.path
        )

        try makeStore().removeLog(filename: "run-1.log")

        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testRemoveLogRejectsSymlinkedDirectoryWithoutDeletingTarget() throws {
        try FileManager.default.createDirectory(
            at: paths.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: paths.directory.path
        )
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let target = outside.appendingPathComponent("run-1.log")
        try Data("must survive".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: paths.logs, withDestinationURL: outside)

        XCTAssertThrowsError(try makeStore().removeLog(filename: "run-1.log"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "must survive")
    }

    private func makeStore(
        fileSystem: any RuntimeLedgerFileSystem = LocalRuntimeLedgerFileSystem()
    ) -> RuntimeLedgerStore {
        RuntimeLedgerStore(
            paths: paths,
            fileSystem: fileSystem,
            makeTemporaryName: { "fixed" }
        )
    }

    private func makeRecord(
        index: Int,
        runID: String? = nil,
        projectID: String? = nil,
        startedAt: String? = nil,
        logFilename: String? = nil
    ) -> RuntimeLedgerRecord {
        RuntimeLedgerRecord(
            runID: runID ?? "run-\(index)",
            projectID: projectID ?? "project-\(index)",
            pid: Int32(1_000 + index),
            processGroupID: Int32(1_000 + index),
            sessionID: Int32(1_000 + index),
            effectiveUserID: 501,
            kernelStartTime: KernelProcessStartTime(
                seconds: UInt64(10_000 + index),
                microseconds: UInt64(index % 1_000_000)
            ),
            commandFingerprint: String(repeating: "a", count: 64),
            observedProcessFingerprint: String(repeating: "b", count: 64),
            port: 4_000 + index,
            startedAt: startedAt ?? "2026-07-18T10:00:\(String(format: "%02d", index % 60))Z",
            logFilename: logFilename ?? "run-\(index).log"
        )
    }

    private func install(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: paths.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: paths.directory.path
        )
        try data.write(to: paths.ledger)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: paths.ledger.path
        )
    }
}

private final class RuntimeLedgerLockAttemptResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedErrorDescription: String?

    var errorDescription: String? {
        lock.withLock { storedErrorDescription }
    }

    func record(_ error: any Error) {
        lock.withLock { storedErrorDescription = error.localizedDescription }
    }
}

private final class FailingRuntimeLedgerFileSystem: RuntimeLedgerFileSystem {
    private let local = LocalRuntimeLedgerFileSystem()
    private let failingDestination: URL

    init(failingDestination: URL) {
        self.failingDestination = failingDestination
    }

    func fileExists(at url: URL) -> Bool { local.fileExists(at: url) }
    func ensureDirectory(at url: URL, permissions: UInt16) throws {
        try local.ensureDirectory(at: url, permissions: permissions)
    }
    func readPrivateData(at url: URL, maximumByteCount: Int) throws -> Data {
        try local.readPrivateData(at: url, maximumByteCount: maximumByteCount)
    }
    func writeFile(_ data: Data, to url: URL, permissions: UInt16) throws {
        try local.writeFile(data, to: url, permissions: permissions)
    }
    func replaceItemAtomically(at destination: URL, with source: URL) throws {
        if destination == failingDestination {
            throw CocoaError(.fileWriteUnknown)
        }
        try local.replaceItemAtomically(at: destination, with: source)
    }
    func syncDirectory(at url: URL) throws { try local.syncDirectory(at: url) }
    func removePrivateFile(named filename: String, in directory: URL) throws {
        try local.removePrivateFile(named: filename, in: directory)
    }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
}

private final class DirectorySyncFailingRuntimeLedgerFileSystem: RuntimeLedgerFileSystem {
    private let local = LocalRuntimeLedgerFileSystem()

    func fileExists(at url: URL) -> Bool { local.fileExists(at: url) }
    func ensureDirectory(at url: URL, permissions: UInt16) throws {
        try local.ensureDirectory(at: url, permissions: permissions)
    }
    func readPrivateData(at url: URL, maximumByteCount: Int) throws -> Data {
        try local.readPrivateData(at: url, maximumByteCount: maximumByteCount)
    }
    func writeFile(_ data: Data, to url: URL, permissions: UInt16) throws {
        try local.writeFile(data, to: url, permissions: permissions)
    }
    func replaceItemAtomically(at destination: URL, with source: URL) throws {
        try local.replaceItemAtomically(at: destination, with: source)
    }
    func syncDirectory(at url: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
    func removePrivateFile(named filename: String, in directory: URL) throws {
        try local.removePrivateFile(named: filename, in: directory)
    }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
}

private final class SpyRuntimeLedgerFileSystem: RuntimeLedgerFileSystem {
    var directoryPermissions: UInt16?
    var filePermissions: UInt16?
    var stagingURL: URL?
    var replacementDestination: URL?
    var replacementSource: URL?
    var syncedDirectory: URL?
    private var existing = Set<URL>()

    func fileExists(at url: URL) -> Bool { existing.contains(url) }
    func ensureDirectory(at url: URL, permissions: UInt16) throws {
        directoryPermissions = permissions
        existing.insert(url)
    }
    func readPrivateData(at url: URL, maximumByteCount: Int) throws -> Data {
        throw CocoaError(.fileReadNoSuchFile)
    }
    func writeFile(_ data: Data, to url: URL, permissions: UInt16) throws {
        filePermissions = permissions
        stagingURL = url
        existing.insert(url)
    }
    func replaceItemAtomically(at destination: URL, with source: URL) throws {
        replacementDestination = destination
        replacementSource = source
        existing.remove(source)
        existing.insert(destination)
    }
    func syncDirectory(at url: URL) throws { syncedDirectory = url }
    func removePrivateFile(named filename: String, in directory: URL) throws {
        existing.remove(directory.appendingPathComponent(filename))
    }
    func removeItem(at url: URL) throws { existing.remove(url) }
}
