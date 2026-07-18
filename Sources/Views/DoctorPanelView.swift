import SwiftUI

struct DoctorPanelView: View {
    let diagnosis: ProjectDiagnosis
    let actionsDisabled: Bool
    let perform: (DoctorActionID) -> Void

    @State private var disclosure = DoctorDisclosureState()
    @State private var timelineExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DoctorDisclosureHeader(
                title: "Project Doctor",
                systemImage: panelIcon,
                iconColor: panelColor,
                summary: compactSummary,
                accessibilityIdentifier: "projectDoctorPanel",
                isExpanded: expansionBinding
            )

            if disclosure.isExpanded {
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
        for validation in diagnosis.validation.errors {
            failureIDs.insert("validation:\(validation.field.rawValue):\(validation.code)")
        }
        return DoctorDisclosureObservation(
            isSettled: diagnosis.hasConfigurationCheck && diagnosis.status != .checking,
            failureIDs: failureIDs
        )
    }

    private var compactSummary: String {
        let passes = diagnosis.checks.count { $0.status == .pass }
        let warnings = diagnosis.checks.count { $0.status == .warn }
        let failures = diagnosis.checks.count { $0.status == .fail }

        return switch diagnosis.status {
        case .idle: diagnosis.hasConfigurationCheck
            ? "Ready to start · \(passes) \(passes == 1 ? "check" : "checks") passed"
            : "Not checked"
        case .checking: "Checking…"
        case .starting: "Starting…"
        case .waiting: "Waiting for readiness…"
        case .ready: "Ready · \(passes) \(passes == 1 ? "check" : "checks") passed"
        case .attention: warnings == 0
            ? "Attention"
            : "Attention · \(warnings) \(warnings == 1 ? "warning" : "warnings")"
        case .failed: failures == 0
            ? "Blocked"
            : "Blocked · \(failures) \(failures == 1 ? "check" : "checks") failed"
        case .stopped: passes == 0
            ? "Stopped"
            : "Stopped · \(passes) \(passes == 1 ? "check" : "checks") passed"
        }
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
        case .idle where diagnosis.hasConfigurationCheck: "checkmark.circle.fill"
        default: "stethoscope"
        }
    }

    private var panelColor: Color {
        switch diagnosis.status {
        case .failed: .red
        case .attention: .orange
        case .ready: .green
        case .idle where diagnosis.hasConfigurationCheck: .green
        case .checking, .starting, .waiting: .blue
        case .idle, .stopped: .secondary
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
