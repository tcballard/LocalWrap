import Foundation

final class RunHistoryService: @unchecked Sendable {
    private let store: any RunHistoryStoring
    private let sanitizer: DiagnosticSanitizer

    init(
        store: any RunHistoryStoring = RunHistoryStore(),
        sanitizer: DiagnosticSanitizer = DiagnosticSanitizer()
    ) {
        self.store = store
        self.sanitizer = sanitizer
    }

    @discardableResult
    func record(_ draft: RunHistoryDraft) throws -> RunHistoryDocument {
        let transitions = draft.transitions.suffix(RunHistoryRecord.maximumTransitions).map {
            RunHistoryTransition(at: safeTimestamp($0.at), state: $0.state)
        }
        let lifecycle = draft.lifecycleExcerpt.suffix(RunHistoryRecord.maximumLifecycleEntries).map {
            RunHistoryLifecycleEntry(at: safeTimestamp($0.at), event: $0.event)
        }
        let record = RunHistoryRecord(
            runReference: sanitizer.opaqueReference(for: draft.runID),
            projectReference: sanitizer.opaqueReference(for: draft.projectID),
            startedAt: safeTimestamp(draft.startedAt),
            endedAt: draft.endedAt.map(safeTimestamp),
            finalState: draft.finalState,
            exitCode: draft.exitCode,
            transitions: transitions,
            lifecycleExcerpt: lifecycle
        )
        return try store.append(record)
    }

    func history() throws -> RunHistoryDocument {
        try store.load()
    }

    @discardableResult
    func clear(projectID: String) throws -> RunHistoryDocument {
        try store.clear(projectReference: sanitizer.opaqueReference(for: projectID))
    }

    func clearAll() throws {
        try store.clearAll()
    }

    private func safeTimestamp(_ value: String) -> String {
        sanitizer.safeTimestamp(value) ?? "unknown"
    }
}
