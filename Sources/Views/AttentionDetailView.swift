import SwiftUI

struct AttentionDetailView: View {
    @Environment(AppModel.self) private var appModel
    @State private var pendingConfirmation: AttentionIssue?
    @State private var historyExpanded = false
    @State private var runHistoryExpanded = false
    @State private var pendingHistoryClear: RunHistoryClearTarget?
    @State private var supportReport: SupportReport?
    @State private var showingSupportReport = false
    @State private var isBuildingSupportReport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if appModel.attentionSnapshot.issues.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Needs Attention", systemImage: "checkmark.circle")
                    } description: {
                        Text("Configuration, runtime, workspace, and preview checks are clear.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .accessibilityIdentifier("attentionEmptyState")
                } else {
                    issueSection(
                        title: "Blockers",
                        issues: appModel.attentionSnapshot.issues.filter { $0.severity == .blocker }
                    )
                    issueSection(
                        title: "Warnings",
                        issues: appModel.attentionSnapshot.issues.filter { $0.severity == .warning }
                    )
                }

                history
                runHistory
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Needs Attention")
        .accessibilityIdentifier("attentionDetail")
        .alert(
            "Apply saved configuration fix?",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            presenting: pendingConfirmation
        ) { issue in
            Button("Apply \(issue.nextAction.label)") {
                pendingConfirmation = nil
                Task { await appModel.performAttentionAction(issue, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {
                pendingConfirmation = nil
            }
        } message: { issue in
            Text(confirmationMessage(for: issue))
        }
        .confirmationDialog(
            "Clear run history?",
            isPresented: Binding(
                get: { pendingHistoryClear != nil },
                set: { if !$0 { pendingHistoryClear = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingHistoryClear
        ) { target in
            Button(target.buttonLabel, role: .destructive) {
                pendingHistoryClear = nil
                Task { await appModel.clearRunHistory(projectID: target.projectID) }
            }
            Button("Cancel", role: .cancel) { pendingHistoryClear = nil }
        } message: { target in
            Text(target.message)
        }
        .sheet(isPresented: $showingSupportReport) {
            if let supportReport {
                SupportReportPreview(
                    report: supportReport,
                    copy: {
                        appModel.copySupportReport(supportReport)
                        showingSupportReport = false
                    },
                    dismiss: { showingSupportReport = false }
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Needs Attention")
                    .font(.title2.bold())
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text("\(appModel.attentionCount) open")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(quantity(
                    appModel.attentionCount,
                    singular: "active issue",
                    plural: "active issues"
                ))
        }
    }

    @ViewBuilder
    private func issueSection(title: String, issues: [AttentionIssue]) -> some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(quantity(issues.count, singular: "issue", plural: "issues"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(issues) { issue in
                        issueRow(issue)
                        if issue.id != issues.last?.id {
                            Divider()
                                .padding(.leading, 37)
                        }
                    }
                }
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func issueRow(_ issue: AttentionIssue) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: issue.severity == .blocker
                ? "exclamationmark.octagon.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .blocker ? .red : .orange)
                .frame(width: 18)
                .padding(.top, 2)
                .accessibilityHidden(true)

            Button {
                appModel.openAttentionIssue(issue)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(issue.scope.displayName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(issue.consequence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(severityLabel(issue.severity)), \(issue.scope.displayName), \(issue.title). "
                    + "Consequence: \(issue.consequence)"
            )
            .accessibilityHint("Opens the affected surface for review.")
            .accessibilityIdentifier("attentionIssue-\(issue.id)")

            Button {
                performNextAction(for: issue)
            } label: {
                Label(
                    issue.nextAction.label,
                    systemImage: issue.nextAction.requiresConfirmation
                        ? "checkmark.shield"
                        : "arrow.right.circle"
                )
                .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help(issue.nextAction.label)
            .accessibilityLabel(issue.nextAction.label)
            .accessibilityHint(issue.nextAction.requiresConfirmation
                ? "Opens a before-and-after confirmation before changing the saved configuration."
                : "Performs the suggested next action.")
            .accessibilityIdentifier("attentionAction-\(issue.id)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    private var history: some View {
        DisclosureGroup(isExpanded: $historyExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if appModel.attentionSnapshot.history.isEmpty {
                    Text("No diagnostic changes recorded this session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.attentionSnapshot.history.prefix(12)) { entry in
                        HStack(spacing: 8) {
                            Text(historyLabel(entry))
                                .font(.callout)
                            Spacer(minLength: 8)
                            Text(entry.recordedAt)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    Button("Clear History") {
                        Task { await appModel.clearAttentionHistory() }
                    }
                    .controlSize(.small)
                    .accessibilityHint("Clears the bounded, redacted diagnostic history for this session.")
                }
            }
            .padding(.top, 7)
        } label: {
            HStack {
                Text("Recent Diagnostic Changes")
                    .font(.headline)
                Spacer()
                Text("\(appModel.attentionSnapshot.history.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(quantity(
                        appModel.attentionSnapshot.history.count,
                        singular: "recorded change",
                        plural: "recorded changes"
                    ))
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("attentionHistory")
    }

    private var runHistory: some View {
        DisclosureGroup(isExpanded: $runHistoryExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let error = appModel.runHistoryErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if appModel.runHistoryDocument.records.isEmpty {
                    Text("No LocalWrap lifecycle history has been captured yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.runHistoryDocument.records.reversed().prefix(8)) { record in
                        runHistoryRow(record)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        previewSupportReport()
                    } label: {
                        Label("Preview Support Report", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(isBuildingSupportReport)
                    .accessibilityHint("Shows the exact redacted text before anything is copied.")
                    .accessibilityIdentifier("previewSupportReportButton")

                    if isBuildingSupportReport {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Building support report")
                    }

                    Spacer()

                    Menu("Clear Run History") {
                        ForEach(appModel.projects) { project in
                            Button(project.name) {
                                pendingHistoryClear = .project(
                                    id: project.id,
                                    name: project.name
                                )
                            }
                        }
                        if !appModel.projects.isEmpty { Divider() }
                        Button("Clear All Run History", role: .destructive) {
                            pendingHistoryClear = .all
                        }
                    }
                    .disabled(appModel.runHistoryDocument.records.isEmpty)
                }
                .controlSize(.small)
            }
            .padding(.top, 7)
        } label: {
            HStack {
                Text("Run History & Support")
                    .font(.headline)
                Spacer()
                Text("\(appModel.runHistoryDocument.records.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(quantity(
                        appModel.runHistoryDocument.records.count,
                        singular: "recorded run",
                        plural: "recorded runs"
                    ))
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("runHistory")
    }

    private func runHistoryRow(_ record: RunHistoryRecord) -> some View {
        HStack(spacing: 9) {
            Image(systemName: runHistoryIcon(record.finalState))
                .foregroundStyle(runHistoryColor(record.finalState))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(projectLabel(for: record))
                    .font(.callout.weight(.medium))
                Text("\(record.finalState.rawValue.replacingOccurrences(of: "-", with: " ")) · \(record.transitions.count) state change\(record.transitions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(record.endedAt ?? record.startedAt)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func previewSupportReport() {
        guard !isBuildingSupportReport else { return }
        isBuildingSupportReport = true
        Task {
            supportReport = await appModel.buildSupportReport()
            isBuildingSupportReport = false
            showingSupportReport = supportReport != nil
        }
    }

    private func projectLabel(for record: RunHistoryRecord) -> String {
        let sanitizer = DiagnosticSanitizer()
        if let project = appModel.projects.first(where: {
            sanitizer.opaqueReference(for: $0.id) == record.projectReference
        }) {
            return project.name
        }
        return "Project \(record.projectReference.prefix(8))"
    }

    private func runHistoryIcon(_ state: RunHistoryState) -> String {
        switch state {
        case .ready, .stopped: "checkmark.circle"
        case .prepared, .starting, .running, .stopping: "clock"
        case .unresponsive: "exclamationmark.triangle"
        case .failed, .exited, .ownershipConflict, .ownershipUnverifiable: "xmark.circle"
        }
    }

    private func runHistoryColor(_ state: RunHistoryState) -> Color {
        switch state {
        case .ready, .stopped: .green
        case .prepared, .starting, .running, .stopping: .blue
        case .unresponsive: .orange
        case .failed, .exited, .ownershipConflict, .ownershipUnverifiable: .red
        }
    }

    private var summary: String {
        let snapshot = appModel.attentionSnapshot
        guard !snapshot.issues.isEmpty else { return "Everything currently looks clear." }

        var parts: [String] = []
        if snapshot.blockerCount > 0 {
            parts.append(quantity(snapshot.blockerCount, singular: "blocker", plural: "blockers"))
        }
        if snapshot.warningCount > 0 {
            parts.append(quantity(snapshot.warningCount, singular: "warning", plural: "warnings"))
        }
        return parts.joined(separator: " · ")
    }

    private func performNextAction(for issue: AttentionIssue) {
        if issue.nextAction.requiresConfirmation {
            pendingConfirmation = issue
        } else {
            Task { await appModel.performAttentionAction(issue) }
        }
    }

    private func confirmationMessage(for issue: AttentionIssue) -> String {
        """
        Before: \(issue.scope.displayName) has “\(issue.title)”. \(issue.consequence)

        After: LocalWrap will apply “\(issue.nextAction.label)” to the saved configuration and immediately recheck this issue.
        """
    }

    private func severityLabel(_ severity: AttentionSeverity) -> String {
        severity == .blocker ? "Blocker" : "Warning"
    }

    private func historyLabel(_ entry: AttentionHistoryEntry) -> String {
        let event: String = switch entry.event {
        case .opened: "Opened"
        case .updated: "Updated"
        case .resolved: "Resolved"
        }
        return "\(event) \(severityLabel(entry.severity).lowercased()) · \(entry.scopeKind.rawValue)"
    }

    private func quantity(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

private enum RunHistoryClearTarget {
    case project(id: String, name: String)
    case all

    var projectID: String? {
        if case .project(let id, _) = self { return id }
        return nil
    }

    var buttonLabel: String {
        switch self {
        case .project(_, let name): "Clear \(name) History"
        case .all: "Clear All Run History"
        }
    }

    var message: String {
        switch self {
        case .project(_, let name):
            "This permanently removes LocalWrap lifecycle history for \(name). Project files and saved configuration are unchanged."
        case .all:
            "This permanently removes all LocalWrap lifecycle history. Project files and saved configuration are unchanged."
        }
    }
}

private struct SupportReportPreview: View {
    let report: SupportReport
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Support Report Preview")
                    .font(.title2.bold())
                Text("This is the exact redacted text that Copy Report will place on the clipboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView([.horizontal, .vertical]) {
                Text(report.previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("supportReportPreviewText")

            HStack {
                Text("\(report.previewText.utf8.count) bytes · no command output or user paths")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Copy Report", action: copy)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("copySupportReportButton")
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }
}
