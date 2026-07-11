import Foundation

struct DoctorReportBuilder: Sendable {
    static let maximumLogLines = 20

    func build(
        project: ProjectDraft,
        runtime: RuntimeSnapshot,
        diagnosis explicitDiagnosis: ProjectDiagnosis? = nil
    ) -> String {
        let diagnosis = explicitDiagnosis ?? runtime.diagnosis
        let checks = diagnosis.checks.map {
            "\($0.label): \($0.status.rawValue) - \($0.message)"
        }
        let timeline = diagnosis.timeline.isEmpty
            ? ["No timeline events."]
            : diagnosis.timeline.map { "\($0.at) \($0.message)" }
        let logs = runtime.logs.suffix(Self.maximumLogLines)
        let recentLogs = logs.isEmpty ? ["No logs."] : Array(logs)
        let exitCode = runtime.exitCode.map { String($0) } ?? "-"
        var lines: [String] = [
            "LocalWrap Doctor Report",
            "Project: \(project.name?.nonempty ?? "Untitled Project")",
            "Directory: \(project.cwd.nonempty ?? "-")",
            "Command: \(project.command.nonempty ?? "-")",
            "Port: \((1...65_535).contains(project.port) ? String(project.port) : "-")",
            "URL: \(project.url.nonempty ?? "-")",
            "Runtime Status: \(runtime.status.rawValue)",
            "Doctor Status: \(diagnosis.status.rawValue)",
            "Summary: \(diagnosis.summary)",
            "Exit Code: \(exitCode)",
            "Readiness: \(runtime.readinessMessage ?? "-")",
            "",
            "Checks:",
        ]
        lines.append(contentsOf: checks)
        lines.append(contentsOf: ["", "Timeline:"])
        lines.append(contentsOf: timeline)
        lines.append(contentsOf: ["", "Recent Logs:"])
        lines.append(contentsOf: recentLogs)
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
