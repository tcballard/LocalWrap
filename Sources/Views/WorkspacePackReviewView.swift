import SwiftUI

struct WorkspacePackReviewView: View {
    let pack: ReviewedWorkspacePack
    let importPack: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Workspace Pack").font(.title2.bold())
            Text(pack.name).foregroundStyle(.secondary)
            List {
                Section("Projects") {
                    ForEach(pack.projects) { project in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                            Text(project.path).font(.caption).foregroundStyle(.secondary)
                            Text(project.draft.command).font(.caption.monospaced())
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("Profiles") {
                    ForEach(pack.profiles) { profile in
                        LabeledContent(profile.name, value: "\(profile.projectIDs.count) projects")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    importPack()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("confirmWorkspacePackImport")
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 480)
        .accessibilityIdentifier("workspacePackReview")
    }
}
