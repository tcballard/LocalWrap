import Foundation

struct RunHistoryPaths: Equatable, Sendable {
    let directory: URL
    let history: URL

    static func production(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> RunHistoryPaths {
        #if DEBUG
        let applicationDirectoryName = "LocalWrapNative-Debug"
        #else
        let applicationDirectoryName = "LocalWrapNative"
        #endif
        let directory = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
        return RunHistoryPaths(
            directory: directory,
            history: directory.appendingPathComponent("run-history.json")
        )
    }
}

enum RunHistoryStoreError: Error, Equatable, LocalizedError {
    case readFailed(String)
    case corruptHistory
    case unsupportedSchema(Int)
    case invalidHistory(String)
    case historyTooLarge(Int)
    case writeFailed(String)
    case durabilityUncertain

    var errorDescription: String? {
        switch self {
        case .readFailed(let message), .invalidHistory(let message), .writeFailed(let message):
            message
        case .corruptHistory:
            "Run history is not valid schema-versioned JSON."
        case .unsupportedSchema(let version):
            "Unsupported run-history schema version: \(version)."
        case .historyTooLarge(let count):
            "Run history is \(count) bytes; the limit is \(RunHistoryDocument.maximumEncodedByteCount)."
        case .durabilityUncertain:
            "Run history was replaced, but filesystem durability could not be confirmed."
        }
    }
}

protocol RunHistoryStoring: Sendable {
    func load() throws -> RunHistoryDocument
    @discardableResult func append(_ record: RunHistoryRecord) throws -> RunHistoryDocument
    @discardableResult func clear(projectReference: String) throws -> RunHistoryDocument
    func clearAll() throws
}

final class RunHistoryStore: RunHistoryStoring, @unchecked Sendable {
    private let paths: RunHistoryPaths
    private let fileSystem: any RuntimeLedgerFileSystem
    private let makeTemporaryName: () -> String
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(
        paths: RunHistoryPaths = .production(),
        fileSystem: any RuntimeLedgerFileSystem = LocalRuntimeLedgerFileSystem(),
        makeTemporaryName: @escaping () -> String = { UUID().uuidString }
    ) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.makeTemporaryName = makeTemporaryName
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    func load() throws -> RunHistoryDocument {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    private func loadUnlocked() throws -> RunHistoryDocument {
        guard fileSystem.fileExists(at: paths.history) else { return .empty }
        let data: Data
        do {
            data = try fileSystem.readPrivateData(
                at: paths.history,
                maximumByteCount: RunHistoryDocument.maximumEncodedByteCount
            )
        } catch {
            throw RunHistoryStoreError.readFailed(
                "Run history could not be read: \(error.localizedDescription)"
            )
        }
        let document: RunHistoryDocument
        do {
            document = try decoder.decode(RunHistoryDocument.self, from: data)
        } catch {
            throw RunHistoryStoreError.corruptHistory
        }
        try validate(document)
        return document
    }

    @discardableResult
    func append(_ record: RunHistoryRecord) throws -> RunHistoryDocument {
        lock.lock()
        defer { lock.unlock() }
        try validate(record)
        var records = try loadUnlocked().records.filter { $0.runReference != record.runReference }
        records.append(record)

        let sameProject = records.indices.filter {
            records[$0].projectReference == record.projectReference
        }
        if sameProject.count > RunHistoryDocument.maximumRecordsPerProject {
            let removeCount = sameProject.count - RunHistoryDocument.maximumRecordsPerProject
            let removals = Set(sameProject.prefix(removeCount))
            records = records.enumerated().filter { !removals.contains($0.offset) }.map(\.element)
        }
        if records.count > RunHistoryDocument.maximumRecordCount {
            records.removeFirst(records.count - RunHistoryDocument.maximumRecordCount)
        }
        return try savePruningToByteLimit(records)
    }

    @discardableResult
    func clear(projectReference: String) throws -> RunHistoryDocument {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isSHA256(projectReference) else {
            throw RunHistoryStoreError.invalidHistory("Project reference is not an opaque digest.")
        }
        let document = try loadUnlocked()
        let remaining = document.records.filter { $0.projectReference != projectReference }
        guard remaining.count != document.records.count else { return document }
        return try save(RunHistoryDocument(records: remaining))
    }

    func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try save(.empty)
    }

    private func savePruningToByteLimit(_ initialRecords: [RunHistoryRecord]) throws -> RunHistoryDocument {
        var records = initialRecords
        while true {
            let document = RunHistoryDocument(records: records)
            let data = try encoded(document)
            if data.count <= RunHistoryDocument.maximumEncodedByteCount {
                try atomicWrite(data)
                return document
            }
            guard !records.isEmpty else {
                throw RunHistoryStoreError.historyTooLarge(data.count)
            }
            records.removeFirst()
        }
    }

    private func save(_ document: RunHistoryDocument) throws -> RunHistoryDocument {
        try validate(document)
        let data = try encoded(document)
        guard data.count <= RunHistoryDocument.maximumEncodedByteCount else {
            throw RunHistoryStoreError.historyTooLarge(data.count)
        }
        try atomicWrite(data)
        return document
    }

    private func encoded(_ document: RunHistoryDocument) throws -> Data {
        do { return try encoder.encode(document) }
        catch {
            throw RunHistoryStoreError.writeFailed(
                "Run history could not be encoded: \(error.localizedDescription)"
            )
        }
    }

    private func atomicWrite(_ data: Data) throws {
        let temporary = paths.directory.appendingPathComponent(
            ".run-history-\(makeTemporaryName()).tmp"
        )
        var replaced = false
        do {
            try fileSystem.ensureDirectory(at: paths.directory, permissions: 0o700)
            try fileSystem.writeFile(data, to: temporary, permissions: 0o600)
            try fileSystem.replaceItemAtomically(at: paths.history, with: temporary)
            replaced = true
            try fileSystem.syncDirectory(at: paths.directory)
        } catch {
            if fileSystem.fileExists(at: temporary) { try? fileSystem.removeItem(at: temporary) }
            if replaced { throw RunHistoryStoreError.durabilityUncertain }
            if let historyError = error as? RunHistoryStoreError { throw historyError }
            throw RunHistoryStoreError.writeFailed(
                "Run history could not be saved: \(error.localizedDescription)"
            )
        }
    }

    private func validate(_ document: RunHistoryDocument) throws {
        guard document.schemaVersion == RunHistoryDocument.currentSchemaVersion else {
            throw RunHistoryStoreError.unsupportedSchema(document.schemaVersion)
        }
        guard document.records.count <= RunHistoryDocument.maximumRecordCount else {
            throw RunHistoryStoreError.invalidHistory("Run history has too many records.")
        }
        var runReferences = Set<String>()
        var counts: [String: Int] = [:]
        for record in document.records {
            try validate(record)
            guard runReferences.insert(record.runReference).inserted else {
                throw RunHistoryStoreError.invalidHistory("Run reference is duplicated.")
            }
            counts[record.projectReference, default: 0] += 1
        }
        guard counts.values.allSatisfy({ $0 <= RunHistoryDocument.maximumRecordsPerProject }) else {
            throw RunHistoryStoreError.invalidHistory("A project has too many run-history records.")
        }
    }

    private func validate(_ record: RunHistoryRecord) throws {
        guard Self.isSHA256(record.runReference), Self.isSHA256(record.projectReference) else {
            throw RunHistoryStoreError.invalidHistory("Run-history references must be opaque digests.")
        }
        guard Self.isSafeTimestamp(record.startedAt),
              record.endedAt.map(Self.isSafeTimestamp) ?? true,
              record.transitions.count <= RunHistoryRecord.maximumTransitions,
              record.lifecycleExcerpt.count <= RunHistoryRecord.maximumLifecycleEntries,
              record.transitions.allSatisfy({ Self.isSafeTimestamp($0.at) }),
              record.lifecycleExcerpt.allSatisfy({ Self.isSafeTimestamp($0.at) }) else {
            throw RunHistoryStoreError.invalidHistory("Run history contains unsafe or unbounded values.")
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isSafeTimestamp(_ value: String) -> Bool {
        value == "unknown" || value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#,
            options: .regularExpression
        ) != nil
    }
}
