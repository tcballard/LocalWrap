import SwiftUI

struct WorkspacePackReviewView: View {
    let review: WorkspacePackReview
    let importPack: () -> Void
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    if !review.issues.isEmpty { issues }
                    projects
                    if !review.profiles.isEmpty { profiles }
                }
                .padding(20)
            }
            Divider()
            actions
        }
        .frame(width: 720, height: 660)
        .accessibilityIdentifier("workspacePackReview")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Review Workspace Manifest")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("workspacePackReviewTitle")
                Text(review.packURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if let version = review.version {
                Text("v\(version)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(20)
    }

    private var summary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    metric("Projects", review.projects.count)
                    metric("New", count(.add))
                    metric("Updates", count(.update))
                    metric("Unchanged", count(.unchanged))
                    Spacer()
                    if review.blockers.isEmpty {
                        Label("Ready to import", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("\(review.blockers.count) blocked", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
                Text("Import only saves reviewed configuration. It does not start projects or execute commands.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(review.name)
        }
    }

    private var issues: some View {
        GroupBox("Review Notes") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(review.issues) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: item.severity == .blocker
                            ? "xmark.octagon.fill"
                            : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.severity == .blocker ? .red : .orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.message)
                            Text(issueContext(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("workspacePackIssue-\(item.code)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var projects: some View {
        GroupBox("Projects") {
            VStack(spacing: 0) {
                ForEach(Array(review.projects.enumerated()), id: \.element.id) { index, project in
                    if index > 0 { Divider().padding(.vertical, 12) }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(project.name).font(.headline)
                if let change = change(.project, id: project.id) {
                    disposition(change.disposition)
                }
                Spacer()
                Text(project.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                detail("Folder", project.path)
                detail("Command", project.command, monospaced: true)
                detail("Address", "Port \(project.port)  •  \(project.url)")
                if !project.dependsOn.isEmpty {
                    detail("Depends on", project.dependsOn.joined(separator: ", "))
                }
                detail("Health", healthSummary(project.healthCheck))
            }
            .font(.callout)
        }
        .accessibilityIdentifier("workspacePackProject-\(project.id)")
    }

    private var profiles: some View {
        GroupBox("Workspaces") {
            VStack(spacing: 8) {
                ForEach(review.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(profile.projectIDs.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let change = change(.workspace, id: profile.id) {
                            disposition(change.disposition)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 4)
        }
    }

    private var actions: some View {
        HStack {
            Button("Cancel") {
                appModel.dismissRepositoryProposal()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("cancelWorkspacePackImport")
            Spacer()
            if !review.canImport {
                Text("Resolve manifest blockers before importing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Import Stopped") { importPack() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!review.canImport)
                .accessibilityIdentifier("confirmWorkspacePackImport")
        }
        .padding(16)
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 54, alignment: .leading)
        .accessibilityElement(children: .combine)
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
    }

    private func dispositionColor(_ value: WorkspacePackChangeDisposition) -> Color {
        switch value {
        case .add: .green
        case .update: .orange
        case .unchanged: .secondary
        }
    }

    private func count(_ disposition: WorkspacePackChangeDisposition) -> Int {
        review.changes.count { $0.entity == .project && $0.disposition == disposition }
    }

    private func change(_ entity: WorkspacePackChangeEntity, id: String) -> WorkspacePackChange? {
        review.changes.first { $0.entity == entity && $0.entityID == id }
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
}
