import SwiftUI

struct DoctorPanelView: View {
    let diagnosis: ProjectDiagnosis
    let actionsDisabled: Bool
    let perform: (DoctorActionID) -> Void

    @State private var isExpanded = true
    @State private var timelineExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(diagnosis.summary)
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("doctorSummary")

                VStack(spacing: 0) {
                    ForEach(diagnosis.checks) { check in
                        checkRow(check)
                        if check.id != DoctorCheckID.allCases.last { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    ForEach(diagnosis.actions, id: \.rawValue) { action in
                        Button(action.label) { perform(action) }
                            .disabled(action.mutatesProject && actionsDisabled)
                            .accessibilityIdentifier("doctorAction-\(action.rawValue)")
                    }
                    Spacer()
                    Button(DoctorActionID.copyReport.label) { perform(.copyReport) }
                        .accessibilityIdentifier("doctorAction-copy-report")
                }

                DisclosureGroup("Timeline", isExpanded: $timelineExpanded) {
                    if diagnosis.timeline.isEmpty {
                        Text("No timeline events.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(diagnosis.timeline) { event in
                            Text("\(event.at)  \(event.message)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityIdentifier("doctorTimeline")
            }
            .padding(.top, 10)
        } label: {
            Label("Project Doctor", systemImage: panelIcon)
                .font(.headline)
                .accessibilityIdentifier("projectDoctorPanel")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func checkRow(_ check: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: check.status))
                .foregroundStyle(color(for: check.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.label).fontWeight(.semibold)
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(check.status.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(color(for: check.status))
        }
        .padding(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.label), \(check.status.rawValue), \(check.message)")
        .accessibilityIdentifier("doctorCheck-\(check.id.rawValue)")
    }

    private var panelIcon: String {
        switch diagnosis.status {
        case .failed: "xmark.octagon.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .ready: "checkmark.circle.fill"
        default: "stethoscope"
        }
    }

    private func icon(for status: DoctorCheckStatus) -> String {
        switch status {
        case .pending: "circle"
        case .running: "clock.fill"
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        }
    }

    private func color(for status: DoctorCheckStatus) -> Color {
        switch status {
        case .pending: .secondary
        case .running: .blue
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        }
    }
}
