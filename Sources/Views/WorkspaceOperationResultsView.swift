import SwiftUI

struct WorkspaceOperationResultsView: View {
    let summary: WorkspaceOperationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last Start Result").font(.headline)
            Text("\(summary.started) started · \(summary.failed) failed · \(summary.skipped) skipped · \(summary.blocked) blocked")
                .foregroundStyle(.secondary)
            ForEach(summary.results) { result in
                HStack(alignment: .top) {
                    Image(systemName: icon(result.status))
                        .foregroundStyle(color(result.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.projectName)
                        Text(result.message).font(.caption).foregroundStyle(.secondary)
                        if !result.blockedByProjectNames.isEmpty {
                            Text("Blocked by: \(result.blockedByProjectNames.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workspaceOperationResult.\(result.projectID)")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("workspaceOperationResults")
    }

    private func icon(_ status: WorkspaceOperationItemStatus) -> String {
        switch status {
        case .started: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "forward.circle.fill"
        case .blocked: "nosign"
        }
    }

    private func color(_ status: WorkspaceOperationItemStatus) -> Color {
        switch status {
        case .started: .green
        case .failed, .blocked: .red
        case .skipped: .orange
        }
    }
}
