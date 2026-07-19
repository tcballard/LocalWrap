import SwiftUI

struct WorkspaceDoctorPanelView: View {
    let diagnosis: WorkspaceDiagnosis
    let navigationRequest: WorkspaceDoctorNavigationRequest?
    let highlightedCheck: WorkspaceCheckID?
    let highlightedProjectID: String?
    let onNavigationAnchorMounted: (WorkspaceDoctorMountedAnchor) -> Void
    let openProject: (String) -> Void

    @State private var disclosure = DoctorDisclosureState()
    @AccessibilityFocusState private var accessibilityFocus: String?

    init(
        diagnosis: WorkspaceDiagnosis,
        navigationRequest: WorkspaceDoctorNavigationRequest? = nil,
        highlightedCheck: WorkspaceCheckID? = nil,
        highlightedProjectID: String? = nil,
        onNavigationAnchorMounted: @escaping (WorkspaceDoctorMountedAnchor) -> Void = { _ in },
        openProject: @escaping (String) -> Void
    ) {
        self.diagnosis = diagnosis
        self.navigationRequest = navigationRequest
        self.highlightedCheck = highlightedCheck
        self.highlightedProjectID = highlightedProjectID
        self.onNavigationAnchorMounted = onNavigationAnchorMounted
        self.openProject = openProject
    }

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
            .id(WorkspaceDoctorAnchor.surface.id)
            .accessibilityFocused(
                $accessibilityFocus,
                equals: WorkspaceDoctorAnchor.surface.id
            )
            .task(id: navigationTaskID(for: .surface)) {
                acknowledgeMounted(.surface)
            }

            if disclosure.isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diagnosis.checks) { check in
                        checkRow(check)
                        if check.id != diagnosis.checks.last?.id { Divider() }
                    }

                    if !diagnosis.checks.isEmpty && !diagnosis.projects.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    ForEach(diagnosis.projects) { project in
                        projectRow(project)
                        if project.id != diagnosis.projects.last?.id {
                            Divider()
                                .padding(.leading, 27)
                        }
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
        .onChange(of: navigationRequest?.id, initial: true) { _, requestID in
            guard requestID != nil else { return }
            disclosure.expand()
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
        case .ready: "Ready · \(quantity(passes, singular: "check", plural: "checks")) passed"
        case .attention: warnings == 0
            ? "Attention"
            : "Attention · \(quantity(warnings, singular: "warning", plural: "warnings"))"
        case .blocked: blockers == 0
            ? "Blocked"
            : "Blocked · \(quantity(blockers, singular: "blocker", plural: "blockers"))"
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

    @ViewBuilder
    private func checkRow(_ check: WorkspaceDoctorCheck) -> some View {
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
        .id(WorkspaceDoctorAnchor.check(check.id).id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.label), \(statusLabel(for: check.status)), \(check.message)")
        .accessibilityFocused(
            $accessibilityFocus,
            equals: WorkspaceDoctorAnchor.check(check.id).id
        )
        .accessibilityIdentifier("workspaceDoctorCheck-\(check.id.rawValue)")
        .task(id: navigationTaskID(for: .check(check.id))) {
            acknowledgeMounted(.check(check.id))
        }
    }

    private func projectRow(_ project: WorkspaceProjectDiagnosis) -> some View {
        Button {
            openProject(project.id)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: projectIcon(project.status))
                    .foregroundStyle(projectColor(project.status))
                    .frame(width: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .fontWeight(.medium)
                    Text(project.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text(projectStatusLabel(for: project.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(projectColor(project.status))

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                project.id == highlightedProjectID ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .id(WorkspaceDoctorAnchor.project(project.id).id)
        .accessibilityLabel("\(project.name), \(projectStatusLabel(for: project.status)), \(project.summary)")
        .accessibilityHint("Opens this project and its diagnostic details.")
        .accessibilityFocused(
            $accessibilityFocus,
            equals: WorkspaceDoctorAnchor.project(project.id).id
        )
        .accessibilityIdentifier("workspaceDiagnosisProject.\(project.id)")
        .task(id: navigationTaskID(for: .project(project.id))) {
            acknowledgeMounted(.project(project.id))
        }
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

    private func statusLabel(for status: WorkspaceCheckStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .pass: "Passed"
        case .warn: "Warning"
        case .fail: "Failed"
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

    private func projectStatusLabel(for status: WorkspaceProjectStatus) -> String {
        switch status {
        case .ready: "Ready"
        case .attention: "Needs attention"
        case .blocked: "Blocked"
        }
    }

    private func quantity(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private func navigationTaskID(for anchor: WorkspaceDoctorAnchor) -> UUID? {
        guard disclosure.isExpanded, navigationRequest?.anchor == anchor else { return nil }
        return navigationRequest?.id
    }

    private func acknowledgeMounted(_ anchor: WorkspaceDoctorAnchor) {
        guard let navigationRequest, navigationRequest.anchor == anchor else { return }
        accessibilityFocus = anchor.id
        onNavigationAnchorMounted(WorkspaceDoctorMountedAnchor(
            requestID: navigationRequest.id,
            anchor: anchor
        ))
    }
}
