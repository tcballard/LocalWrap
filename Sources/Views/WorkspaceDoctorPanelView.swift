import SwiftUI

struct WorkspaceDoctorPanelView: View {
    let diagnosis: WorkspaceDiagnosis
    let openProject: (String) -> Void
    @State private var disclosure = DoctorDisclosureState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DoctorDisclosureHeader(
                title: "Workspace Doctor",
                systemImage: panelIcon,
                iconColor: panelColor,
                summary: compactSummary,
                accessibilityIdentifier: "workspaceDoctorPanel",
                isExpanded: expansionBinding
            )

            if disclosure.isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(diagnosis.checks) { check in
                        checkRow(check)
                    }
                    Divider()
                    ForEach(diagnosis.projects) { project in
                        Button {
                            openProject(project.id)
                        } label: {
                            HStack {
                                Image(systemName: projectIcon(project.status))
                                    .foregroundStyle(projectColor(project.status))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                    Text(project.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workspaceDiagnosisProject.\(project.id)")
                    }
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: disclosureObservation, initial: true) { _, observation in
            disclosure.observe(observation)
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { disclosure.isExpanded },
            set: { disclosure.setExpanded($0) }
        )
    }

    private var disclosureObservation: DoctorDisclosureObservation {
        var failureIDs = Set(
            diagnosis.checks
                .filter { $0.status == .fail }
                .map { "check:\($0.id.rawValue)" }
        )
        for project in diagnosis.projects where project.status == .blocked {
            failureIDs.insert("project:\(project.id):blocked")
            for issue in project.issues where issue.severity == .blocker {
                failureIDs.insert("project:\(project.id):\(issue.check.rawValue):\(issue.code)")
            }
        }
        return DoctorDisclosureObservation(isSettled: true, failureIDs: failureIDs)
    }

    private var compactSummary: String {
        let passes = diagnosis.checks.count { $0.status == .pass }
        let warnings = diagnosis.totals.warnings
        let blockers = diagnosis.totals.blockers

        return switch diagnosis.status {
        case .empty: "No saved projects"
        case .ready: "Ready · \(passes) \(passes == 1 ? "check" : "checks") passed"
        case .attention: warnings == 0
            ? "Attention"
            : "Attention · \(warnings) \(warnings == 1 ? "warning" : "warnings")"
        case .blocked: blockers == 0
            ? "Blocked"
            : "Blocked · \(blockers) \(blockers == 1 ? "blocker" : "blockers")"
        }
    }

    private var panelIcon: String {
        switch diagnosis.status {
        case .empty: "stethoscope"
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private var panelColor: Color {
        switch diagnosis.status {
        case .empty: .secondary
        case .ready: .green
        case .attention: .orange
        case .blocked: .red
        }
    }

    private func checkRow(_ check: WorkspaceDoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: check.status))
                .foregroundStyle(color(for: check.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.label).fontWeight(.semibold)
                Text(check.message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(check.status.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(color(for: check.status))
        }
        .padding(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.label), \(check.status.rawValue), \(check.message)")
        .accessibilityIdentifier("workspaceDoctorCheck-\(check.id.rawValue)")
    }

    private func icon(for status: WorkspaceCheckStatus) -> String {
        switch status {
        case .pending: "circle.dotted"
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        }
    }

    private func color(for status: WorkspaceCheckStatus) -> Color {
        switch status {
        case .pending: .secondary
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        }
    }

    private func projectIcon(_ status: WorkspaceProjectStatus) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .blocked: "xmark.circle.fill"
        }
    }

    private func projectColor(_ status: WorkspaceProjectStatus) -> Color {
        switch status {
        case .ready: .green
        case .attention: .orange
        case .blocked: .red
        }
    }
}
