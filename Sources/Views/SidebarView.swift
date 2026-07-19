import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selection: AppSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                AttentionSidebarRow(snapshot: appModel.attentionSnapshot)
                    .tag(AppSelection.attention)
                    .accessibilityIdentifier("attentionSidebarRow")
            } header: {
                Text("Status")
            }

            Section {
                WorkspaceSidebarRow(
                    title: "All Projects",
                    detail: "\(appModel.projectCount) saved",
                    icon: "square.stack.3d.up"
                )
                .tag(AppSelection.workspace(.allProjects))
                .accessibilityIdentifier("allProjectsWorkspaceRow")
                if !appModel.workspace.lastRunningProjectIds.isEmpty {
                    WorkspaceSidebarRow(
                        title: "Last Running",
                        detail: "\(appModel.workspace.lastRunningProjectIds.count) projects",
                        icon: "clock.arrow.circlepath"
                    )
                    .tag(AppSelection.workspace(.lastRunning))
                }
                ForEach(appModel.workspace.savedWorkspaces) { profile in
                    WorkspaceSidebarRow(
                        title: profile.name,
                        detail: "\(profile.projectIds.count) projects",
                        icon: "square.stack.3d.up"
                    )
                    .tag(AppSelection.workspace(.profile(profile.id)))
                }
            } header: {
                Text("Workspaces")
                    .accessibilityIdentifier("workspacesSection")
            }

            Section {
                if appModel.projects.isEmpty {
                    Label("No saved projects", systemImage: "terminal")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No saved projects")
                } else {
                    ForEach(appModel.projects) { project in
                        ProjectSidebarRow(
                            project: project,
                            runtime: appModel.runtime(for: project.id)
                        )
                        .tag(AppSelection.project(project.id))
                    }
                }
            } header: {
                Text("Projects")
                    .accessibilityIdentifier("projectsSection")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        .accessibilityIdentifier("sidebar")
    }
}

private struct AttentionSidebarRow: View {
    let snapshot: AttentionSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Needs Attention")
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if snapshot.count > 0 {
                Text("\(snapshot.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Needs Attention, \(detail)")
    }

    private var statusIcon: String {
        if snapshot.blockerCount > 0 { return "exclamationmark.octagon.fill" }
        if snapshot.warningCount > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if snapshot.blockerCount > 0 { return .red }
        if snapshot.warningCount > 0 { return .orange }
        return .green
    }

    private var detail: String {
        guard snapshot.count > 0 else { return "All clear" }
        var parts: [String] = []
        if snapshot.blockerCount > 0 {
            parts.append("\(snapshot.blockerCount) blocker\(snapshot.blockerCount == 1 ? "" : "s")")
        }
        if snapshot.warningCount > 0 {
            parts.append("\(snapshot.warningCount) warning\(snapshot.warningCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }
}

private struct WorkspaceSidebarRow: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }
}

private struct ProjectSidebarRow: View {
    let project: Project
    let runtime: RuntimeSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                Text(runtime.status.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name), \(runtime.status.rawValue)")
    }

    private var statusIcon: String {
        switch runtime.status {
        case .ready: "checkmark.circle.fill"
        case .starting, .stopping: "clock.fill"
        case .runningUnresponsive: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .stopped: "circle"
        }
    }

    private var statusColor: Color {
        switch runtime.status {
        case .ready: .green
        case .starting, .stopping: .blue
        case .runningUnresponsive: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}
