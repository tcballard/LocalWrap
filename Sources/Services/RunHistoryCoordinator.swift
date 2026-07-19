import Foundation

actor RunHistoryCoordinator {
    private let service: RunHistoryService
    private let reportBuilder: SupportReportBuilder

    init(
        service: RunHistoryService = RunHistoryService(),
        reportBuilder: SupportReportBuilder = SupportReportBuilder()
    ) {
        self.service = service
        self.reportBuilder = reportBuilder
    }

    func load() throws -> RunHistoryDocument {
        try service.history()
    }

    func record(_ draft: RunHistoryDraft) throws -> RunHistoryDocument {
        try service.record(draft)
    }

    func clear(projectID: String) throws -> RunHistoryDocument {
        try service.clear(projectID: projectID)
    }

    func clearAll() throws -> RunHistoryDocument {
        try service.clearAll()
        return .empty
    }

    func supportReport(generatedAt: String) throws -> SupportReport {
        reportBuilder.build(history: try service.history(), generatedAt: generatedAt)
    }
}
