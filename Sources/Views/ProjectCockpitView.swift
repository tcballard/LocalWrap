import SwiftUI

struct ProjectCockpitView: View {
    @Environment(AppModel.self) private var appModel
    let projectID: String
    @Binding var selection: AppSelection?
    @State private var editorIsDirty = false
    @State private var previewState = PreviewState()
    @State private var confirmsDeletion = false

    var body: some View {
        if let project = appModel.project(id: projectID) {
            let runtime = appModel.runtime(for: projectID)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(project: project, runtime: runtime)
                    ProjectEditorView(
                        project: project,
                        runtime: runtime,
                        selection: $selection,
                        isDirty: $editorIsDirty
                    )
                        .frame(minHeight: 430)
                    if previewState.isVisible {
                        ProjectPreviewView(
                            project: project,
                            state: $previewState,
                            openExternal: appModel.openExternalWebURL
                        )
                    }
                    logPanel(runtime: runtime)
                }
                .padding(24)
            }
            .navigationTitle(project.name)
            .focusedSceneValue(
                \.projectCommandActions,
                commandActions(runtime: runtime)
            )
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: openPreview) {
                        Label("Preview", systemImage: "macwindow")
                    }
                    .disabled(runtime.status != .ready || editorIsDirty || previewState.isVisible)
                    .help("Preview Project")
                    .accessibilityIdentifier("previewProjectButton")

                    Button { appModel.openProjectURL(id: projectID) } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .disabled(runtime.status != .ready)
                    .help("Open in Browser")
                    .accessibilityIdentifier("openProjectButton")

                    Button(action: start) {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(runtime.status.isActive || editorIsDirty)
                    .help("Start Project")
                    .accessibilityIdentifier("startProjectButton")

                    Button(action: stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(!runtime.status.isActive)
                    .help("Stop Project")
                    .accessibilityIdentifier("stopProjectButton")

                    Button(action: restart) {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canRestart(runtime.status) || editorIsDirty)
                    .help("Restart Project")
                    .accessibilityIdentifier("restartProjectButton")
                }
            }
            .onChange(of: runtime.status) { _, status in
                if status != .ready {
                    previewState.close()
                }
            }
            .onDisappear { previewState.close() }
        } else {
            ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
        }
    }

    @ViewBuilder
    private func header(project: Project, runtime: RuntimeSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.largeTitle.bold())
                Text(runtime.readinessMessage ?? "Project is stopped.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("projectReadinessMessage")
            }
            Spacer()
            Text(runtime.status.rawValue)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
                .accessibilityIdentifier("projectStatus")
            Menu {
                Button("Clear Logs") {
                    Task { await appModel.clearLogs(projectID: projectID) }
                }
                Divider()
                Button("Delete Project", role: .destructive) {
                    confirmsDeletion = true
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .confirmationDialog(
                "Delete \(project.name)?",
                isPresented: $confirmsDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete Project", role: .destructive) {
                    previewState.close()
                    Task {
                        await appModel.stopProject(id: projectID)
                        appModel.deleteProject(id: projectID)
                        selection = .projects
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the saved project from LocalWrap. Project files are not deleted.")
            }
        }
    }

    @ViewBuilder
    private func logPanel(runtime: RuntimeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output").font(.headline)
            ScrollView {
                Text(runtime.logs.isEmpty ? "No output yet." : runtime.logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(minHeight: 180, maxHeight: 300)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .accessibilityIdentifier("projectLogOutput")
        }
    }

    private func commandActions(runtime: RuntimeSnapshot) -> ProjectCommandActions {
        ProjectCommandActions(
            canStart: !runtime.status.isActive && !editorIsDirty,
            canStop: runtime.status.isActive,
            canRestart: canRestart(runtime.status) && !editorIsDirty,
            start: start,
            stop: stop,
            restart: restart
        )
    }

    private func start() {
        Task { try? await appModel.startProject(id: projectID) }
    }

    private func stop() {
        Task { await appModel.stopProject(id: projectID) }
    }

    private func restart() {
        Task { try? await appModel.restartProject(id: projectID) }
    }

    private func openPreview() {
        guard let project = appModel.project(id: projectID),
              appModel.runtime(for: projectID).status == .ready,
              !editorIsDirty,
              let url = LocalURLValidator().url(from: project.url) else { return }
        previewState.open(url)
    }

    private func canRestart(_ status: RuntimeStatus) -> Bool {
        status != .starting && status != .stopping
    }
}
