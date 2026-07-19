import CryptoKit
import Foundation

struct DoctorReportBuilder: Sendable {
    static let maximumReportByteCount = 8 * 1_024

    func report(
        project: ProjectDraft,
        runtime: RuntimeSnapshot,
        diagnosis explicitDiagnosis: ProjectDiagnosis? = nil
    ) -> DoctorReport {
        DoctorReport(text: build(
            project: project,
            runtime: runtime,
            diagnosis: explicitDiagnosis
        ))
    }

    func build(
        project: ProjectDraft,
        runtime: RuntimeSnapshot,
        diagnosis explicitDiagnosis: ProjectDiagnosis? = nil
    ) -> String {
        let diagnosis = explicitDiagnosis ?? runtime.diagnosis
        let checks = diagnosis.checks.map { "\($0.label): \($0.status.rawValue)" }
        let timeline = diagnosis.timeline.isEmpty
            ? ["No lifecycle events."]
            : diagnosis.timeline.suffix(ProjectDiagnosis.maximumTimelineEvents).map {
                "\(Self.safeTimestamp($0.at)) \($0.status.rawValue)"
            }
        let exitCode = runtime.exitCode.map { String($0) } ?? "-"
        var lines: [String] = [
            "LocalWrap Redacted Doctor Report",
            "Privacy: paths, commands, URLs, logs, messages, and environment values are omitted.",
            "Project reference: \(Self.projectReference(project.id))",
            "Name configured: \(Self.isPresent(project.name) ? "yes" : "no")",
            "Directory configured: \(Self.isPresent(project.cwd) ? "yes" : "no")",
            "Command configured: \(Self.isPresent(project.command) ? "yes" : "no")",
            "Port: \((1...65_535).contains(project.port) ? String(project.port) : "-")",
            "Local URL configured: \(Self.isPresent(project.url) ? "yes" : "no")",
            "Runtime Status: \(runtime.status.rawValue)",
            "Doctor Status: \(diagnosis.status.rawValue)",
            "Exit Code: \(exitCode)",
            "",
            "Checks:",
        ]
        lines.append(contentsOf: checks)
        lines.append(contentsOf: ["", "Lifecycle:"])
        lines.append(contentsOf: timeline)
        lines.append("")
        let report = lines.joined(separator: "\n")
        return Self.utf8Prefix(report, maximumByteCount: Self.maximumReportByteCount) + "\n"
    }

    private static func isPresent(_ value: String?) -> Bool {
        !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func projectReference(_ value: String?) -> String {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 128 else { return "unsaved" }
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeTimestamp(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789-:TZ+.")
        let filtered = String(value.unicodeScalars.filter(allowed.contains))
        return String(filtered.prefix(40)).nonempty ?? "-"
    }

    private static func utf8Prefix(_ value: String, maximumByteCount: Int) -> String {
        guard value.utf8.count > maximumByteCount else { return value }
        var result = ""
        result.reserveCapacity(maximumByteCount)
        var count = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard count + bytes <= maximumByteCount else { break }
            result.append(character)
            count += bytes
        }
        return result
    }
}

private extension String {
    var nonempty: String? {
        isEmpty ? nil : self
    }
}
