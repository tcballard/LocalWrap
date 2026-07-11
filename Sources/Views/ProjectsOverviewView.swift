import SwiftUI

struct ProjectsOverviewView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selection: AppSelection?

    var body: some View {
        if appModel.projects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "terminal")
            } description: {
                Text("Add a local project to create its cockpit.")
            } actions: {
                Button("Add Project") { selection = .newProject }
            }
        } else {
            List(appModel.projects) { project in
                Button {
                    selection = .project(project.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.name).font(.headline)
                            Text(project.cwd).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(appModel.runtime(for: project.id).status.rawValue)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Projects")
        }
    }
}
