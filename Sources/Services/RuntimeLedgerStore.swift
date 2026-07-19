import Darwin
import Foundation

protocol RuntimeLedgerFileSystem {
    func fileExists(at url: URL) -> Bool
    func ensureDirectory(at url: URL, permissions: UInt16) throws
    func readPrivateData(at url: URL, maximumByteCount: Int) throws -> Data
    func writeFile(_ data: Data, to url: URL, permissions: UInt16) throws
    func replaceItemAtomically(at destination: URL, with source: URL) throws
    func syncDirectory(at url: URL) throws
    func removePrivateFile(named filename: String, in directory: URL) throws
    func removeItem(at url: URL) throws
}

private enum RuntimeLedgerFileSystemError: Error {
    case insecureDirectory
    case insecureFile
    case exceedsMaximumByteCount(Int)
}

struct LocalRuntimeLedgerFileSystem: RuntimeLedgerFileSystem {
    private let manager = FileManager.default
    private let effectiveUserID: () -> uid_t

    init(effectiveUserID: @escaping () -> uid_t = { geteuid() }) {
        self.effectiveUserID = effectiveUserID
    }

    func fileExists(at url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    func ensureDirectory(at url: URL, permissions: UInt16) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw posixError(operation: "inspect runtime ledger directory")
            }
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: permissions)]
            )
            guard lstat(url.path, &metadata) == 0 else {
                throw posixError(operation: "inspect created runtime ledger directory")
            }
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == effectiveUserID() else {
            throw RuntimeLedgerFileSystemError.insecureDirectory
        }
        guard chmod(url.path, mode_t(permissions)) == 0 else {
            throw posixError(operation: "secure runtime ledger directory")
        }
    }

    func readPrivateData(at url: URL, maximumByteCount: Int) throws -> Data {
        let directoryURL = url.deletingLastPathComponent().standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent() == directoryURL,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".." else {
            throw RuntimeLedgerFileSystemError.insecureFile
        }

        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw RuntimeLedgerFileSystemError.insecureDirectory
            }
            throw posixError(operation: "open runtime ledger directory")
        }
        defer { _ = close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0 else {
            throw posixError(operation: "inspect runtime ledger directory")
        }
        guard (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              directoryMetadata.st_uid == effectiveUserID(),
              (directoryMetadata.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw RuntimeLedgerFileSystemError.insecureDirectory
        }

        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw RuntimeLedgerFileSystemError.insecureFile
            }
            throw posixError(operation: "open runtime ledger")
        }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw posixError(operation: "inspect runtime ledger")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == effectiveUserID(),
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw RuntimeLedgerFileSystemError.insecureFile
        }
        guard metadata.st_size >= 0 else {
            throw RuntimeLedgerFileSystemError.insecureFile
        }
        guard metadata.st_size <= off_t(maximumByteCount) else {
            throw RuntimeLedgerFileSystemError.exceedsMaximumByteCount(Int(metadata.st_size))
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let remaining = maximumByteCount - data.count
            let requested = min(buffer.count, remaining + 1)
            let bytesRead = Darwin.read(descriptor, &buffer, requested)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw posixError(operation: "read runtime ledger")
            }
            if bytesRead == 0 { break }
            let count = Int(bytesRead)
            guard count <= remaining else {
                throw RuntimeLedgerFileSystemError.exceedsMaximumByteCount(data.count + count)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    func writeFile(_ data: Data, to url: URL, permissions: UInt16) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(permissions)
        )
        guard descriptor >= 0 else {
            throw posixError(operation: "create runtime ledger staging file")
        }

        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove {
                _ = unlink(url.path)
            }
        }

        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw posixError(operation: "secure runtime ledger staging file")
        }

        try data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(operation: "write runtime ledger staging file")
                }
                guard written > 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                remaining -= written
                address = address.advanced(by: written)
            }
        }

        guard fsync(descriptor) == 0 else {
            throw posixError(operation: "flush runtime ledger staging file")
        }
        shouldRemove = false
    }

    func replaceItemAtomically(at destination: URL, with source: URL) throws {
        let destinationDirectory = destination.deletingLastPathComponent().standardizedFileURL
        let sourceDirectory = source.deletingLastPathComponent().standardizedFileURL
        guard destinationDirectory == sourceDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard rename(source.path, destination.path) == 0 else {
            throw posixError(operation: "replace runtime ledger")
        }
    }

    func removeItem(at url: URL) throws {
        try manager.removeItem(at: url)
    }

    func syncDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError(operation: "open runtime ledger directory for flushing")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == effectiveUserID(),
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw RuntimeLedgerFileSystemError.insecureDirectory
        }
        guard fsync(descriptor) == 0 else {
            throw posixError(operation: "flush runtime ledger directory")
        }
    }

    func removePrivateFile(named filename: String, in directory: URL) throws {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/") else {
            throw RuntimeLedgerFileSystemError.insecureFile
        }
        let directoryDescriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return }
            if errno == ELOOP || errno == ENOTDIR {
                throw RuntimeLedgerFileSystemError.insecureDirectory
            }
            throw posixError(operation: "open runtime log directory")
        }
        defer { _ = close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0 else {
            throw posixError(operation: "inspect runtime log directory")
        }
        guard (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              directoryMetadata.st_uid == effectiveUserID(),
              (directoryMetadata.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw RuntimeLedgerFileSystemError.insecureDirectory
        }

        var fileMetadata = stat()
        guard fstatat(directoryDescriptor, filename, &fileMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw posixError(operation: "inspect runtime log")
        }
        guard (fileMetadata.st_mode & S_IFMT) == S_IFREG,
              fileMetadata.st_uid == effectiveUserID(),
              fileMetadata.st_nlink == 1,
              (fileMetadata.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw RuntimeLedgerFileSystemError.insecureFile
        }
        guard unlinkat(directoryDescriptor, filename, 0) == 0 else {
            if errno == ENOENT { return }
            throw posixError(operation: "remove runtime log")
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw posixError(operation: "flush runtime log directory")
        }
    }

    private func posixError(operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "Could not \(operation): \(String(cString: strerror(code))).",
            ]
        )
    }
}

struct RuntimeLedgerPaths: Equatable, Sendable {
    let directory: URL
    let ledger: URL

    var logs: URL {
        directory.appendingPathComponent("runtime-logs", isDirectory: true)
    }

    static func production(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> RuntimeLedgerPaths {
        #if DEBUG
        let applicationDirectoryName = "LocalWrapNative-Debug"
        #else
        let applicationDirectoryName = "LocalWrapNative"
        #endif
        let directory = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
        return RuntimeLedgerPaths(
            directory: directory,
            ledger: directory.appendingPathComponent("runtime-ledger.json")
        )
    }
}

enum RuntimeLedgerError: Error, Equatable, LocalizedError {
    case readFailed(String)
    case corruptLedger(String)
    case insecureLedger
    case ledgerTooLarge(actualByteCount: Int)
    case unsupportedSchema(Int)
    case tooManyRecords(Int)
    case invalidRecord(runID: String, reason: String)
    case invalidLogFilename(String)
    case writeFailed(String)
    case durabilityUncertain

    var errorDescription: String? {
        switch self {
        case .readFailed(let message), .corruptLedger(let message), .writeFailed(let message):
            message
        case .insecureLedger:
            "Runtime ledger is not a private regular file owned by the current user."
        case .ledgerTooLarge(let actualByteCount):
            "Runtime ledger contains \(actualByteCount) bytes; the maximum is \(RuntimeLedgerDocument.maximumEncodedByteCount)."
        case .unsupportedSchema(let version):
            "Unsupported runtime ledger schema version: \(version)."
        case .tooManyRecords(let count):
            "Runtime ledger contains \(count) records; the maximum is \(RuntimeLedgerDocument.maximumRecordCount)."
        case .invalidRecord(let runID, let reason):
            "Runtime ledger record \"\(runID)\" is invalid: \(reason)"
        case .invalidLogFilename(let filename):
            "Runtime log filename is invalid: \(filename)"
        case .durabilityUncertain:
            "Runtime ledger was replaced, but filesystem durability could not be confirmed."
        }
    }
}

protocol RuntimeLedgerStoring: Sendable {
    func acquireExclusiveLock() throws -> any RuntimeLedgerLock
    func load() throws -> RuntimeLedgerDocument
    @discardableResult func save(_ document: RuntimeLedgerDocument) throws -> RuntimeLedgerDocument
    @discardableResult func upsert(_ record: RuntimeLedgerRecord) throws -> RuntimeLedgerDocument
    @discardableResult func remove(runID: String) throws -> RuntimeLedgerDocument
    func logURL(for filename: String) throws -> URL
    func removeLog(filename: String) throws
}

protocol RuntimeLedgerLock: Sendable {
    func unlock()
}

private final class NoopRuntimeLedgerLock: RuntimeLedgerLock, @unchecked Sendable {
    func unlock() {}
}

extension RuntimeLedgerStoring {
    func acquireExclusiveLock() throws -> any RuntimeLedgerLock {
        NoopRuntimeLedgerLock()
    }
}

private final class LocalRuntimeLedgerLock: RuntimeLedgerLock, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func unlock() {
        let descriptor = lock.withLock { () -> Int32? in
            defer { self.descriptor = nil }
            return self.descriptor
        }
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit { unlock() }
}

final class RuntimeLedgerStore: RuntimeLedgerStoring, @unchecked Sendable {
    private let paths: RuntimeLedgerPaths
    private let fileSystem: any RuntimeLedgerFileSystem
    private let makeTemporaryName: () -> String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        paths: RuntimeLedgerPaths = .production(),
        fileSystem: any RuntimeLedgerFileSystem = LocalRuntimeLedgerFileSystem(),
        makeTemporaryName: @escaping () -> String = { UUID().uuidString }
    ) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.makeTemporaryName = makeTemporaryName
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func load() throws -> RuntimeLedgerDocument {
        guard fileSystem.fileExists(at: paths.ledger) else {
            return .empty
        }

        let data: Data
        do {
            data = try fileSystem.readPrivateData(
                at: paths.ledger,
                maximumByteCount: RuntimeLedgerDocument.maximumEncodedByteCount
            )
        } catch RuntimeLedgerFileSystemError.insecureDirectory,
                RuntimeLedgerFileSystemError.insecureFile {
            throw RuntimeLedgerError.insecureLedger
        } catch RuntimeLedgerFileSystemError.exceedsMaximumByteCount(let actualByteCount) {
            throw RuntimeLedgerError.ledgerTooLarge(actualByteCount: actualByteCount)
        } catch {
            throw RuntimeLedgerError.readFailed(
                "Runtime ledger could not be read: \(error.localizedDescription)"
            )
        }

        try validateJSONShape(data)

        let version: RuntimeLedgerVersionEnvelope
        do {
            version = try decoder.decode(RuntimeLedgerVersionEnvelope.self, from: data)
        } catch {
            throw corruptLedgerError()
        }
        guard version.schemaVersion == RuntimeLedgerDocument.currentSchemaVersion else {
            throw RuntimeLedgerError.unsupportedSchema(version.schemaVersion)
        }

        let document: RuntimeLedgerDocument
        do {
            document = try decoder.decode(RuntimeLedgerDocument.self, from: data)
        } catch {
            throw corruptLedgerError()
        }
        try validate(document, trimExcessRecords: false)
        return document
    }

    func acquireExclusiveLock() throws -> any RuntimeLedgerLock {
        try fileSystem.ensureDirectory(at: paths.directory, permissions: 0o700)
        let lockURL = paths.directory.appendingPathComponent(".runtime-ledger.lock")
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw RuntimeLedgerError.writeFailed("Runtime ledger lock could not be opened.")
        }
        var shouldClose = true
        defer { if shouldClose { close(descriptor) } }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              fchmod(descriptor, 0o600) == 0 else {
            throw RuntimeLedgerError.writeFailed("Runtime ledger lock is not a private regular file.")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw RuntimeLedgerError.writeFailed("Runtime ledger lock could not be acquired.")
        }
        shouldClose = false
        return LocalRuntimeLedgerLock(descriptor: descriptor)
    }

    @discardableResult
    func save(_ document: RuntimeLedgerDocument) throws -> RuntimeLedgerDocument {
        guard document.schemaVersion == RuntimeLedgerDocument.currentSchemaVersion else {
            throw RuntimeLedgerError.unsupportedSchema(document.schemaVersion)
        }
        try validate(document, trimExcessRecords: false)

        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw RuntimeLedgerError.writeFailed(
                "Runtime ledger could not be encoded: \(error.localizedDescription)"
            )
        }
        guard data.count <= RuntimeLedgerDocument.maximumEncodedByteCount else {
            throw RuntimeLedgerError.ledgerTooLarge(actualByteCount: data.count)
        }
        try atomicWrite(data)
        return document
    }

    @discardableResult
    func upsert(_ record: RuntimeLedgerRecord) throws -> RuntimeLedgerDocument {
        var records = try load().records
        records.removeAll { $0.runID == record.runID }
        records.append(record)
        return try save(RuntimeLedgerDocument(records: records))
    }

    @discardableResult
    func remove(runID: String) throws -> RuntimeLedgerDocument {
        let existing = try load()
        let remaining = existing.records.filter { $0.runID != runID }
        guard remaining.count != existing.records.count else {
            return existing
        }
        return try save(RuntimeLedgerDocument(records: remaining))
    }

    func logURL(for filename: String) throws -> URL {
        guard Self.isSafeLogFilename(filename) else {
            throw RuntimeLedgerError.invalidLogFilename(filename)
        }
        return paths.logs.appendingPathComponent(filename, isDirectory: false)
    }

    func removeLog(filename: String) throws {
        _ = try logURL(for: filename)
        try fileSystem.removePrivateFile(named: filename, in: paths.logs)
    }

    private func atomicWrite(_ data: Data) throws {
        let temporary = paths.directory.appendingPathComponent(
            ".runtime-ledger-\(makeTemporaryName()).tmp"
        )
        var didReplaceLedger = false
        do {
            try fileSystem.ensureDirectory(at: paths.directory, permissions: 0o700)
            try fileSystem.writeFile(data, to: temporary, permissions: 0o600)
            try fileSystem.replaceItemAtomically(at: paths.ledger, with: temporary)
            didReplaceLedger = true
            do {
                try fileSystem.syncDirectory(at: paths.directory)
            } catch {
                throw RuntimeLedgerError.durabilityUncertain
            }
        } catch {
            if fileSystem.fileExists(at: temporary) {
                try? fileSystem.removeItem(at: temporary)
            }
            if let ledgerError = error as? RuntimeLedgerError {
                throw ledgerError
            }
            if didReplaceLedger {
                throw RuntimeLedgerError.durabilityUncertain
            }
            throw RuntimeLedgerError.writeFailed(
                "Runtime ledger could not be saved: \(error.localizedDescription)"
            )
        }
    }

    private func validate(
        _ document: RuntimeLedgerDocument,
        trimExcessRecords: Bool
    ) throws {
        guard document.schemaVersion == RuntimeLedgerDocument.currentSchemaVersion else {
            throw RuntimeLedgerError.unsupportedSchema(document.schemaVersion)
        }
        if !trimExcessRecords,
           document.records.count > RuntimeLedgerDocument.maximumRecordCount {
            throw RuntimeLedgerError.tooManyRecords(document.records.count)
        }

        var runIDs = Set<String>()
        var projectIDs = Set<String>()
        for record in document.records {
            try validate(record)
            guard runIDs.insert(record.runID).inserted else {
                throw RuntimeLedgerError.invalidRecord(
                    runID: record.runID,
                    reason: "run ID is duplicated."
                )
            }
            guard projectIDs.insert(record.projectID).inserted else {
                throw RuntimeLedgerError.invalidRecord(
                    runID: record.runID,
                    reason: "project ID is already associated with another active run."
                )
            }
        }
    }

    private func validate(_ record: RuntimeLedgerRecord) throws {
        let runID = record.runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runID.isEmpty else {
            throw RuntimeLedgerError.invalidRecord(runID: record.runID, reason: "run ID is empty.")
        }
        guard runID == record.runID,
              record.runID.utf8.count <= RuntimeLedgerRecord.maximumIdentifierByteCount,
              !record.runID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RuntimeLedgerError.invalidRecord(
                runID: "[invalid identifier]",
                reason: "run ID is not a bounded, single-line identifier."
            )
        }
        let projectID = record.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectID.isEmpty else {
            throw RuntimeLedgerError.invalidRecord(runID: runID, reason: "project ID is empty.")
        }
        guard projectID == record.projectID,
              record.projectID.utf8.count <= RuntimeLedgerRecord.maximumIdentifierByteCount,
              !record.projectID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RuntimeLedgerError.invalidRecord(
                runID: runID,
                reason: "project ID is not a bounded, single-line identifier."
            )
        }
        guard record.pid > 0, record.processGroupID > 0, record.sessionID > 0 else {
            throw RuntimeLedgerError.invalidRecord(
                runID: runID,
                reason: "PID, process group, and session must be positive."
            )
        }
        guard record.pid == record.processGroupID,
              record.pid == record.sessionID else {
            throw RuntimeLedgerError.invalidRecord(
                runID: runID,
                reason: "the isolated process leader, group, and session identities must match."
            )
        }
        guard record.kernelStartTime.isValid else {
            throw RuntimeLedgerError.invalidRecord(
                runID: runID,
                reason: "kernel start time is outside its valid range."
            )
        }
        guard isSHA256(record.commandFingerprint),
              isSHA256(record.observedProcessFingerprint) else {
            throw RuntimeLedgerError.invalidRecord(
                runID: runID,
                reason: "process fingerprints must be SHA-256 hex digests."
            )
        }
        guard (1_000...65_535).contains(record.port) else {
            throw RuntimeLedgerError.invalidRecord(runID: runID, reason: "port is outside 1000...65535.")
        }
        let startedAt = record.startedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !startedAt.isEmpty else {
            throw RuntimeLedgerError.invalidRecord(runID: runID, reason: "start time is empty.")
        }
        guard startedAt == record.startedAt,
              record.startedAt.utf8.count <= RuntimeLedgerRecord.maximumTimestampByteCount,
              !record.startedAt.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RuntimeLedgerError.invalidRecord(
                runID: runID,
                reason: "start time is not a bounded, single-line value."
            )
        }
        guard record.logFilename.utf8.count <= RuntimeLedgerRecord.maximumLogFilenameByteCount else {
            throw RuntimeLedgerError.invalidRecord(runID: runID, reason: "log filename is too long.")
        }
        guard Self.isSafeLogFilename(record.logFilename) else {
            throw RuntimeLedgerError.invalidRecord(
                runID: runID,
                reason: "log filename must be a filename, not a path."
            )
        }
    }

    private static func isSafeLogFilename(_ value: String) -> Bool {
        let filename = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !filename.isEmpty
            && filename == value
            && filename != "."
            && filename != ".."
            && URL(fileURLWithPath: filename).lastPathComponent == filename
    }

    private func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private func validateJSONShape(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw corruptLedgerError()
        }
        guard let root = object as? [String: Any],
              Set(root.keys).isSubset(of: ["schemaVersion", "records"]),
              root["schemaVersion"] != nil,
              let records = root["records"] as? [Any] else {
            throw corruptLedgerError()
        }
        let allowedRecordKeys: Set<String> = [
            "phase", "runID", "projectID", "pid", "processGroupID", "sessionID", "effectiveUserID",
            "kernelStartTime", "commandFingerprint", "observedProcessFingerprint", "port",
            "startedAt", "logFilename",
        ]
        let requiredStartTimeKeys: Set<String> = ["seconds", "microseconds"]
        for value in records {
            guard let record = value as? [String: Any],
                  Set(record.keys) == allowedRecordKeys,
                  let startTime = record["kernelStartTime"] as? [String: Any],
                  Set(startTime.keys) == requiredStartTimeKeys else {
                throw corruptLedgerError()
            }
        }
    }

    private func corruptLedgerError() -> RuntimeLedgerError {
        .corruptLedger("Runtime ledger is not valid schema-versioned JSON.")
    }
}

private struct RuntimeLedgerVersionEnvelope: Decodable {
    let schemaVersion: Int
}
