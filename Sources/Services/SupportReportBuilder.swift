import Foundation

struct SupportReportBuilder: Sendable {
    private let sanitizer: DiagnosticSanitizer

    init(sanitizer: DiagnosticSanitizer = DiagnosticSanitizer()) {
        self.sanitizer = sanitizer
    }

    func build(history: RunHistoryDocument, generatedAt: String) -> SupportReport {
        let timestamp = sanitizer.safeTimestamp(generatedAt) ?? "unknown"
        var text = [
            "LocalWrap Support Report",
            "Format: 1",
            "Generated: \(timestamp)",
            "Runs available: \(min(history.records.count, RunHistoryDocument.maximumRecordCount))",
            "",
        ].joined(separator: "\n")

        var omitted = 0
        for record in history.records.reversed().prefix(RunHistoryDocument.maximumRecordCount) {
            let block = render(record)
            if (text + block).utf8.count > SupportReport.maximumUTF8ByteCount {
                omitted += 1
                continue
            }
            text += block
        }
        if omitted > 0 {
            let suffix = "\n[\(omitted) older run(s) omitted to keep this report bounded.]\n"
            if (text + suffix).utf8.count <= SupportReport.maximumUTF8ByteCount {
                text += suffix
            }
        }
        text = sanitizer.truncateUTF8(text, maximumByteCount: SupportReport.maximumUTF8ByteCount)
        return SupportReport(text: text)
    }

    private func render(_ record: RunHistoryRecord) -> String {
        var lines = [
            "",
            "Run \(coarse(record.runReference)) / Project \(coarse(record.projectReference))",
            "Started: \(safeTimestamp(record.startedAt))",
            "Ended: \(record.endedAt.map(safeTimestamp) ?? "unknown")",
            "Final state: \(record.finalState.rawValue)",
            "Exit code: \(record.exitCode.map(String.init) ?? "unknown")",
        ]
        if !record.transitions.isEmpty {
            lines.append("Transitions:")
            lines.append(contentsOf: record.transitions.suffix(RunHistoryRecord.maximumTransitions).map {
                "- \(safeTimestamp($0.at)) \($0.state.rawValue)"
            })
        }
        if !record.lifecycleExcerpt.isEmpty {
            lines.append("LocalWrap lifecycle:")
            lines.append(contentsOf: record.lifecycleExcerpt.suffix(RunHistoryRecord.maximumLifecycleEntries).map {
                "- \(safeTimestamp($0.at)) \($0.event.rawValue)"
            })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func coarse(_ reference: String) -> String {
        let safeReference: String
        if reference.utf8.count == 64,
           reference.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            safeReference = reference
        } else {
            safeReference = sanitizer.opaqueReference(for: reference)
        }
        return String(safeReference.prefix(12))
    }

    private func safeTimestamp(_ value: String) -> String {
        sanitizer.safeTimestamp(value) ?? "unknown"
    }
}
