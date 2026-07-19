import SwiftUI

struct DoctorPanelView: View {
    let diagnosis: ProjectDiagnosis
    let actionsDisabled: Bool
    let expansionRequestID: UUID?
    let highlightedCheck: DoctorCheckID?
    let perform: (DoctorActionID) -> Void
    let buildReport: () -> DoctorReport
    let copyReport: (DoctorReport) -> Void

    @State private var disclosure = DoctorDisclosureState()
    @State private var timelineExpanded = false
    @State private var reportPreview: DoctorReport?
    @AccessibilityFocusState private var accessibilityFocus: String?

    init(
        diagnosis: ProjectDiagnosis,
        actionsDisabled: Bool,
        expansionRequestID: UUID? = nil,
        highlightedCheck: DoctorCheckID? = nil,
        perform: @escaping (DoctorActionID) -> Void,
        buildReport: @escaping () -> DoctorReport,
        copyReport: @escaping (DoctorReport) -> Void
    ) {
        self.diagnosis = diagnosis
        self.actionsDisabled = actionsDisabled
        self.expansionRequestID = expansionRequestID
        self.highlightedCheck = highlightedCheck
        self.perform = perform
        self.buildReport = buildReport
        self.copyReport = copyReport
    }

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
            .id(Self.surfaceAnchor)
            .accessibilityFocused($accessibilityFocus, equals: Self.surfaceAnchor)
            .task(id: focusTaskID(for: Self.surfaceAnchor)) {
                acknowledgeMountedFocusAnchor(Self.surfaceAnchor)
            }

            if disclosure.isExpanded {
                VStack(alignment: .leading, spacing: 10) {
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

                    HStack(spacing: 8) {
                        ForEach(
                            diagnosis.actions.filter { $0 != .copyReport },
                            id: \.rawValue
                        ) { action in
                            Button(action.label) { perform(action) }
                                .controlSize(.small)
                                .disabled(action.mutatesProject && actionsDisabled)
                                .accessibilityHint(action.mutatesProject
                                    ? "Changes the saved project after validation."
                                    : "Performs this Project Doctor action.")
                                .accessibilityIdentifier("doctorAction-\(action.rawValue)")
                        }

                        Spacer(minLength: 8)

                        Button("Preview Redacted Report") {
                            reportPreview = buildReport()
                        }
                        .controlSize(.small)
                        .help("Review the exact redacted text before copying it")
                        .accessibilityHint(
                            "Opens the bounded redacted report. Copy is available only from that preview."
                        )
                        .accessibilityIdentifier("doctorAction-preview-report")
                    }

                    DisclosureGroup(isExpanded: $timelineExpanded) {
                        VStack(alignment: .leading, spacing: 5) {
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
                        .padding(.top, 6)
                    } label: {
                        Text("Timeline")
                            .font(.callout.weight(.medium))
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
        .onChange(of: expansionRequestID, initial: true) { _, requestID in
            guard requestID != nil else { return }
            disclosure.expand()
        }
        .sheet(isPresented: reportPreviewPresented) {
            if let reportPreview {
                DoctorReportPreview(
                    report: reportPreview,
                    copy: {
                        copyReport(reportPreview)
                        self.reportPreview = nil
                    },
                    dismiss: { self.reportPreview = nil }
                )
            }
        }
    }

    private var reportPreviewPresented: Binding<Bool> {
        Binding(
            get: { reportPreview != nil },
            set: { presented in
                if !presented { reportPreview = nil }
            }
        )
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
            ? "Ready to start · \(quantity(passes, singular: "check", plural: "checks")) passed"
            : "Not checked"
        case .checking: "Checking…"
        case .starting: "Starting…"
        case .waiting: "Waiting for readiness…"
        case .ready: "Ready · \(quantity(passes, singular: "check", plural: "checks")) passed"
        case .attention: warnings == 0
            ? "Attention"
            : "Attention · \(quantity(warnings, singular: "warning", plural: "warnings"))"
        case .failed: failures == 0
            ? "Blocked"
            : "Blocked · \(quantity(failures, singular: "check", plural: "checks")) failed"
        case .stopped: passes == 0
            ? "Stopped"
            : "Stopped · \(quantity(passes, singular: "check", plural: "checks")) passed"
        }
    }

    private var requestedFocusAnchor: String {
        highlightedCheck.map(Self.checkAnchor) ?? Self.surfaceAnchor
    }

    private func focusTaskID(for anchor: String) -> String? {
        guard let expansionRequestID,
              requestedFocusAnchor == anchor else { return nil }
        return "\(expansionRequestID.uuidString)|\(anchor)"
    }

    private func acknowledgeMountedFocusAnchor(_ anchor: String) {
        guard focusTaskID(for: anchor) != nil else { return }
        accessibilityFocus = anchor
    }

    @ViewBuilder
    private func checkRow(_ check: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon(for: check.status))
                .foregroundStyle(color(for: check.status))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.label)
                    .fontWeight(.semibold)
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(statusLabel(for: check.status))
                .font(.caption.weight(.medium))
                .foregroundStyle(color(for: check.status))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            check.id == highlightedCheck ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .id(Self.checkAnchor(check.id))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.label), \(statusLabel(for: check.status)), \(check.message)")
        .accessibilityFocused($accessibilityFocus, equals: Self.checkAnchor(check.id))
        .accessibilityIdentifier("doctorCheck-\(check.id.rawValue)")
        .task(id: focusTaskID(for: Self.checkAnchor(check.id))) {
            acknowledgeMountedFocusAnchor(Self.checkAnchor(check.id))
        }
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

    private func statusLabel(for status: DoctorCheckStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .running: "Running"
        case .pass: "Passed"
        case .warn: "Warning"
        case .fail: "Failed"
        }
    }

    private func quantity(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private static let surfaceAnchor = "projectDoctorSurface"

    private static func checkAnchor(_ check: DoctorCheckID) -> String {
        "projectDoctorCheck-\(check.rawValue)"
    }
}

private struct DoctorReportPreview: View {
    let report: DoctorReport
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Project Doctor Report Preview")
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
            .accessibilityIdentifier("doctorReportPreviewText")

            HStack {
                Text("\(report.previewText.utf8.count) bytes · paths, commands, URLs, logs, and secrets omitted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Copy Report", action: copy)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("copyDoctorReportButton")
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }
}
