import SwiftUI

struct WorkspaceDoctorPanelView: View {
    let diagnosis: WorkspaceDiagnosis
    let openProject: (String) -> Void
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
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
            .padding(.top, 10)
        } label: {
            HStack {
                Label("Workspace Doctor", systemImage: "stethoscope")
                    .font(.headline)
                    .accessibilityIdentifier("workspaceDoctorPanel")
                Spacer()
                Text(diagnosis.summary).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
