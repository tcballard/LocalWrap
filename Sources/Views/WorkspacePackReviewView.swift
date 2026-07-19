import SwiftUI

struct WorkspacePackReviewView: View {
    let review: WorkspacePackReview
    let importPack: () -> Void
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var copiedPath = false
    @State private var stoppingAffectedProjects = false
    @State private var expandedProjectIDs: Set<String>
    @State private var expandedWorkspaceIDs: Set<String>

    init(review: WorkspacePackReview, importPack: @escaping () -> Void) {
        self.review = review
        self.importPack = importPack
        _expandedProjectIDs = State(initialValue: Self.initiallyExpandedIDs(
            in: review,
            entity: .project
        ))
        _expandedWorkspaceIDs = State(initialValue: Self.initiallyExpandedIDs(
            in: review,
            entity: .workspace
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    if review.canImport, let importBlockReason {
                        importPaused(importBlockReason)
                    }
                    if !review.issues.isEmpty { issues }
                    projects
                    if !review.profiles.isEmpty { profiles }
                }
                .padding(20)
            }
            Divider()
            actions
        }
        .frame(
            minWidth: 680,
            idealWidth: 780,
            maxWidth: 920,
            minHeight: 560,
            idealHeight: 700,
            maxHeight: 900
        )
        .accessibilityIdentifier("workspacePackReview")
        .onChange(of: review) { _, newReview in
            expandedProjectIDs = Self.initiallyExpandedIDs(in: newReview, entity: .project)
            expandedWorkspaceIDs = Self.initiallyExpandedIDs(in: newReview, entity: .workspace)
            copiedPath = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Review Workspace Manifest")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("workspacePackReviewTitle")
                Spacer()
                if let version = review.version {
                    Text("Manifest v\(version)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("Manifest version \(version)")
                }
            }
            HStack(spacing: 8) {
                Text(review.packURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("workspacePackManifestPath")
                Spacer(minLength: 12)
                Button("Reveal Manifest", systemImage: "folder") {
                    appModel.revealWorkspaceManifest(review)
                }
                .accessibilityIdentifier("revealWorkspaceManifest")
                Button(copiedPath ? "Copied" : "Copy Path", systemImage: copiedPath ? "checkmark" : "doc.on.doc") {
                    appModel.copyWorkspaceManifestPath(review)
                    copiedPath = true
                }
                .accessibilityIdentifier("copyWorkspaceManifestPath")
                Button("Review Again", systemImage: "arrow.clockwise") {
                    appModel.reviewWorkspaceManifestAgain(review)
                }
                .accessibilityIdentifier("reviewWorkspaceManifestAgain")
            }
            .controlSize(.small)
        }
        .padding(20)
    }

    private var summary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    metric("Projects", review.projects.count, id: "projects")
                    metric("Workspaces", review.profiles.count, id: "workspaces")
                    metric("Warnings", review.warnings.count, id: "warnings")
                    metric("Blockers", review.blockers.count, id: "blockers")
                    Spacer()
                    readinessLabel
                }
                Divider()
                HStack(spacing: 24) {
                    changeSummary("Projects", entity: .project)
                    changeSummary("Workspaces", entity: .workspace)
                }
                Text("Import saves only the reviewed configuration. Projects remain stopped and no commands run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(review.name)
        }
    }

    @ViewBuilder
    private var readinessLabel: some View {
        if importBlockReason == nil {
            Label(readyTitle, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if review.blockers.isEmpty {
            Label("Import paused", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
        } else {
            Label("Import blocked", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func importPaused(_ reason: String) -> some View {
        Label {
            HStack(spacing: 12) {
                Text(reason)
                Spacer()
                if !activeUpdateProjectIDs.isEmpty {
                    if stoppingAffectedProjects {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Stopping affected projects")
                    }
                    Button("Stop Affected Projects", systemImage: "stop.fill") {
                        stoppingAffectedProjects = true
                        Task {
                            await appModel.stopProjectsBlockingWorkspacePackImport(review)
                            stoppingAffectedProjects = false
                        }
                    }
                    .disabled(stoppingAffectedProjects)
                    .accessibilityIdentifier("stopWorkspacePackAffectedProjects")
                }
            }
        } icon: {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("workspacePackImportPaused")
    }

    private var issues: some View {
        GroupBox("Review Notes") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(orderedIssues) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: item.severity == .blocker
                            ? "xmark.octagon.fill"
                            : "exclamationmark.triangle.fill")
                            .foregroundStyle(severityColor(item.severity))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(severityTitle(item.severity))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(severityColor(item.severity))
                                Text(item.message)
                            }
                            Text(issueContext(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(severityTitle(item.severity)): \(item.message). \(issueContext(item))")
                    .accessibilityIdentifier(issueIdentifier(item))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var projects: some View {
        GroupBox("Projects") {
            LazyVStack(spacing: 0) {
                ForEach(Array(review.projects.enumerated()), id: \.element.id) { index, project in
                    if index > 0 { Divider().padding(.vertical, 10) }
                    projectRow(project)
                }
                if review.projects.isEmpty {
                    Text("No readable projects were found in this manifest.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 4)
        }
    }

    private func projectRow(_ project: WorkspacePackReviewProject) -> some View {
        DisclosureGroup(isExpanded: projectExpansion(project.id)) {
            Group {
                if change(.project, id: project.id)?.disposition == .update,
                   let existing = existingProject(for: project.id) {
                    projectComparison(project, existing: existing)
                } else {
                    projectDetails(project)
                }
            }
            .padding(.top, 9)
        } label: {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.headline)
                    .accessibilityIdentifier("workspacePackProject-\(project.id)")
                if let change = change(.project, id: project.id) {
                    disposition(change.disposition)
                }
                Spacer()
                if change(.project, id: project.id)?.disposition == .unchanged {
                    Text("No changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(project.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func projectDetails(_ project: WorkspacePackReviewProject) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            detail("Folder", project.path)
            detail("Command", project.command, monospaced: true)
            detail("Address", "Port \(project.port)  •  \(project.url)")
            detail("Starts automatically", enabledTitle(project.autostart))
            detail("Opens browser when ready", enabledTitle(project.openOnReady))
            detail("Depends on", proposedProjectNames(project.dependsOn))
            detail("Health", healthSummary(project.healthCheck))
        }
        .font(.callout)
        .accessibilityIdentifier("workspacePackProjectDetails-\(project.id)")
    }

    private func projectComparison(
        _ project: WorkspacePackReviewProject,
        existing: Project
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Current saved values compared with this manifest")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Field")
                    Text("Current")
                    Text("Manifest")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(projectComparisons(project, existing: existing)) { comparison in
                    GridRow {
                        HStack(spacing: 5) {
                            if comparison.changed {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                            }
                            Text(comparison.label)
                        }
                        comparisonValue(comparison.before, comparison: comparison)
                        comparisonValue(comparison.after, comparison: comparison)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(comparisonAccessibilityLabel(comparison))
                    .accessibilityIdentifier("workspacePackProject-\(project.id)-field-\(comparison.id)")
                }
            }
        }
        .accessibilityIdentifier("workspacePackProjectComparison-\(project.id)")
    }

    private func comparisonValue(
        _ value: String,
        comparison: WorkspaceReviewFieldComparison
    ) -> some View {
        Text(value)
            .font(comparison.monospaced ? .callout.monospaced() : .callout)
            .foregroundStyle(comparison.changed ? .primary : .secondary)
            .lineLimit(2)
            .textSelection(.enabled)
    }

    private var profiles: some View {
        GroupBox("Workspaces") {
            LazyVStack(spacing: 0) {
                ForEach(Array(review.profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { Divider().padding(.vertical, 8) }
                    profileRow(profile)
                }
            }
            .padding(.top, 4)
        }
    }

    private func profileRow(_ profile: WorkspacePackReviewProfile) -> some View {
        DisclosureGroup(isExpanded: workspaceExpansion(profile.id)) {
            Group {
                if change(.workspace, id: profile.id)?.disposition == .update,
                   let existing = existingWorkspace(for: profile.id) {
                    profileComparison(profile, existing: existing)
                } else {
                    detailGrid("Projects", proposedProjectNames(profile.projectIDs))
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text(profile.name)
                    .accessibilityIdentifier("workspacePackWorkspace-\(profile.id)")
                if let change = change(.workspace, id: profile.id) {
                    disposition(change.disposition)
                }
                Spacer()
                if change(.workspace, id: profile.id)?.disposition == .unchanged {
                    Text("No changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func profileComparison(
        _ profile: WorkspacePackReviewProfile,
        existing: WorkspaceProfile
    ) -> some View {
        let comparisons = [
            WorkspaceReviewFieldComparison(
                id: "name",
                label: "Name",
                before: existing.name,
                after: profile.name
            ),
            WorkspaceReviewFieldComparison(
                id: "projects",
                label: "Projects",
                before: savedProjectNames(existing.projectIds),
                after: proposedProjectNames(profile.projectIDs)
            ),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                Text("Field")
                Text("Current")
                Text("Manifest")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(comparisons) { comparison in
                GridRow {
                    HStack(spacing: 5) {
                        if comparison.changed {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                        }
                        Text(comparison.label)
                    }
                    Text(comparison.before)
                    Text(comparison.after)
                }
                .font(.callout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(comparisonAccessibilityLabel(comparison))
                .accessibilityIdentifier("workspacePackWorkspace-\(profile.id)-field-\(comparison.id)")
            }
        }
        .accessibilityIdentifier("workspacePackWorkspaceComparison-\(profile.id)")
    }

    private func detailGrid(_ label: String, _ value: String) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14) {
            detail(label, value)
        }
        .font(.callout)
    }

    private var actions: some View {
        HStack(alignment: .center, spacing: 12) {
            Button("Cancel") {
                appModel.dismissRepositoryProposal()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("cancelWorkspacePackImport")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let importBlockReason {
                    Text(importBlockReason)
                        .foregroundStyle(review.blockers.isEmpty ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
                Text("Projects remain stopped after import.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Button("Import Projects") { importPack() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(importBlockReason != nil)
                .accessibilityHint("Imports configuration only. Projects remain stopped.")
                .accessibilityIdentifier("confirmWorkspacePackImport")
        }
        .padding(16)
    }

    private var importBlockReason: String? {
        appModel.workspacePackImportBlockReason(for: review)
    }

    private var activeUpdateProjectIDs: [String] {
        appModel.workspacePackActiveUpdateProjectIDs(for: review)
    }

    private var readyTitle: String {
        guard !review.warnings.isEmpty else { return "Ready to import" }
        return "Ready with \(review.warnings.count) warning\(review.warnings.count == 1 ? "" : "s")"
    }

    private var orderedIssues: [WorkspacePackReviewIssue] {
        review.issues.sorted { lhs, rhs in
            let lhsRank = lhs.severity == .blocker ? 0 : 1
            let rhsRank = rhs.severity == .blocker ? 0 : 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (lhs.scope, lhs.field ?? "", lhs.code, lhs.message)
                < (rhs.scope, rhs.field ?? "", rhs.code, rhs.message)
        }
    }

    private func metric(_ label: String, _ value: Int, id: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 62, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspacePackMetric-\(id)")
    }

    private func changeSummary(_ label: String, entity: WorkspacePackChangeEntity) -> some View {
        let added = count(entity, disposition: .add)
        let updated = count(entity, disposition: .update)
        let unchanged = count(entity, disposition: .unchanged)
        return Text("\(label): \(added) new  •  \(updated) updated  •  \(unchanged) unchanged")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("workspacePackChangeSummary-\(entity.rawValue)")
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func disposition(_ value: WorkspacePackChangeDisposition) -> some View {
        Text(value.rawValue.capitalized)
            .font(.caption.weight(.medium))
            .foregroundStyle(dispositionColor(value))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(dispositionColor(value).opacity(0.12), in: Capsule())
            .accessibilityLabel("Change: \(value.rawValue)")
    }

    private func dispositionColor(_ value: WorkspacePackChangeDisposition) -> Color {
        switch value {
        case .add: .green
        case .update: .orange
        case .unchanged: .secondary
        }
    }

    private func severityColor(_ value: WorkspacePackReviewSeverity) -> Color {
        value == .blocker ? .red : .orange
    }

    private func severityTitle(_ value: WorkspacePackReviewSeverity) -> String {
        value == .blocker ? "Blocker" : "Warning"
    }

    private func count(
        _ entity: WorkspacePackChangeEntity,
        disposition: WorkspacePackChangeDisposition
    ) -> Int {
        review.changes.count { $0.entity == entity && $0.disposition == disposition }
    }

    private func change(_ entity: WorkspacePackChangeEntity, id: String) -> WorkspacePackChange? {
        review.changes.first { $0.entity == entity && $0.entityID == id }
    }

    private func existingProject(for manifestID: String) -> Project? {
        guard let savedID = change(.project, id: manifestID)?.existingSavedID else { return nil }
        return appModel.project(id: savedID)
    }

    private func existingWorkspace(for manifestID: String) -> WorkspaceProfile? {
        guard let savedID = change(.workspace, id: manifestID)?.existingSavedID else { return nil }
        return appModel.workspace.savedWorkspaces.first { $0.id == savedID }
    }

    private func projectComparisons(
        _ project: WorkspacePackReviewProject,
        existing: Project
    ) -> [WorkspaceReviewFieldComparison] {
        [
            WorkspaceReviewFieldComparison(
                id: "name", label: "Name", before: existing.name, after: project.name
            ),
            WorkspaceReviewFieldComparison(
                id: "folder",
                label: "Folder",
                before: displayPath(existing.cwd),
                after: project.path
            ),
            WorkspaceReviewFieldComparison(
                id: "command",
                label: "Command",
                before: existing.command,
                after: project.command,
                monospaced: true
            ),
            WorkspaceReviewFieldComparison(
                id: "port",
                label: "Port",
                before: String(existing.port),
                after: String(project.port),
                monospaced: true
            ),
            WorkspaceReviewFieldComparison(
                id: "url", label: "URL", before: existing.url, after: project.url
            ),
            WorkspaceReviewFieldComparison(
                id: "autostart",
                label: "Starts automatically",
                before: enabledTitle(existing.autostart),
                after: enabledTitle(project.autostart)
            ),
            WorkspaceReviewFieldComparison(
                id: "open-on-ready",
                label: "Opens browser when ready",
                before: enabledTitle(existing.openOnReady),
                after: enabledTitle(project.openOnReady)
            ),
            WorkspaceReviewFieldComparison(
                id: "dependencies",
                label: "Depends on",
                before: savedProjectNames(existing.dependsOn ?? []),
                after: proposedProjectNames(project.dependsOn)
            ),
            WorkspaceReviewFieldComparison(
                id: "health",
                label: "Health",
                before: healthSummary(existing.healthCheck),
                after: healthSummary(project.healthCheck)
            ),
        ]
    }

    private func displayPath(_ absolutePath: String) -> String {
        let rootPath = review.rootURL.standardizedFileURL.path
        let path = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        if path == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    private func proposedProjectNames(_ ids: [String]) -> String {
        relationshipSummary(ids.map { id in
            review.projects.first { $0.id == id }?.name ?? id
        })
    }

    private func savedProjectNames(_ ids: [String]) -> String {
        relationshipSummary(ids.map { id in appModel.project(id: id)?.name ?? id })
    }

    private func relationshipSummary(_ names: [String]) -> String {
        names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private func enabledTitle(_ enabled: Bool) -> String {
        enabled ? "Yes" : "No"
    }

    private func healthSummary(_ healthCheck: HealthCheck?) -> String {
        guard let healthCheck else { return "Project URL" }
        if let path = healthCheck.path { return path }
        return healthCheck.url ?? "Project URL"
    }

    private func issueContext(_ item: WorkspacePackReviewIssue) -> String {
        guard let field = item.field else { return item.scope }
        return "\(item.scope) • \(field)"
    }

    private func issueIdentifier(_ item: WorkspacePackReviewIssue) -> String {
        [
            "workspacePackIssue",
            item.severity.rawValue,
            stableToken(item.code),
            stableToken(item.scope),
            stableToken(item.field ?? "general"),
        ].joined(separator: "-")
    }

    private func stableToken(_ value: String) -> String {
        String(value.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        })
    }

    private func comparisonAccessibilityLabel(_ comparison: WorkspaceReviewFieldComparison) -> String {
        if comparison.changed {
            return "\(comparison.label) changed from \(comparison.before) to \(comparison.after)"
        }
        return "\(comparison.label) unchanged: \(comparison.after)"
    }

    private func projectExpansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedProjectIDs.contains(id) },
            set: { expanded in
                if expanded { expandedProjectIDs.insert(id) }
                else { expandedProjectIDs.remove(id) }
            }
        )
    }

    private func workspaceExpansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedWorkspaceIDs.contains(id) },
            set: { expanded in
                if expanded { expandedWorkspaceIDs.insert(id) }
                else { expandedWorkspaceIDs.remove(id) }
            }
        )
    }

    private static func initiallyExpandedIDs(
        in review: WorkspacePackReview,
        entity: WorkspacePackChangeEntity
    ) -> Set<String> {
        Set(review.changes.compactMap { change in
            guard change.entity == entity, change.disposition != .unchanged else { return nil }
            return change.entityID
        })
    }
}

private struct WorkspaceReviewFieldComparison: Identifiable {
    let id: String
    let label: String
    let before: String
    let after: String
    var monospaced = false

    var changed: Bool { before != after }
}
