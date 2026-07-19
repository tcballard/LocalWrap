import SwiftUI

struct ProjectCockpitView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let projectID: String
    @Binding var selection: AppSelection?
    @State private var editorIsDirty = false
    @State private var previewState = PreviewState()
    @State private var previewViewport: PreviewViewportPreset = .fit
    @State private var confirmsDeletion = false
    @State private var scrollRequest: ProjectScrollRequest?
    @State private var editorAttentionRequest: AttentionNavigationRequest?

    var body: some View {
        if let project = appModel.project(id: projectID) {
            let runtime = appModel.runtime(for: projectID)
            Group {
                if previewState.isVisible {
                    HSplitView {
                        projectContent(project: project, runtime: runtime)
                            .frame(minWidth: 300, idealWidth: 430)

                        ProjectPreviewView(
                            project: project,
                            state: $previewState,
                            viewport: $previewViewport,
                            openExternal: appModel.openExternalWebURL
                        )
                        .frame(minWidth: 320, idealWidth: 560)
                    }
                    .accessibilityIdentifier("projectLiveSplitView")
                } else {
                    projectContent(project: project, runtime: runtime)
                }
            }
            .navigationTitle(project.name)
            .focusedSceneValue(
                \.projectCommandActions,
                commandActions(runtime: runtime)
            )
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: togglePreview) {
                        Label(
                            "Live Preview",
                            systemImage: previewState.isVisible
                                ? "rectangle.righthalf.inset.filled"
                                : "rectangle.righthalf.inset"
                        )
                    }
                    .disabled(runtime.status != .ready || editorIsDirty)
                    .help(previewState.isVisible ? "Close Live Preview" : "Show Live Preview")
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
                    .disabled(
                        !appModel.runtimeControlsAvailable
                            || runtime.status.isActive
                            || runtime.ownership.hasUnresolvedRun
                            || editorIsDirty
                    )
                    .help("Start Project")
                    .accessibilityIdentifier("startProjectButton")

                    Button(action: stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(
                        !appModel.runtimeControlsAvailable
                            || !runtime.status.isActive
                            || !canSignal(runtime)
                    )
                    .help("Stop Project")
                    .accessibilityIdentifier("stopProjectButton")

                    Button(action: restart) {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .disabled(
                        !appModel.runtimeControlsAvailable
                            || !canSignal(runtime)
                            || !canRestart(runtime.status)
                            || editorIsDirty
                    )
                    .help("Restart Project")
                    .accessibilityIdentifier("restartProjectButton")
                }
            }
            .onChange(of: runtime.status) { _, status in
                if status != .ready {
                    previewState.close()
                }
            }
            .onChange(of: project.url) { _, value in
                guard previewState.isVisible else { return }
                guard let url = LocalURLValidator().url(from: value) else {
                    previewState.close()
                    return
                }
                previewState.open(url)
            }
            .onChange(of: previewState.attentionFailureEvidence) { _, _ in
                appModel.reportPreviewState(projectID: projectID, state: previewState)
            }
            .task(id: appModel.navigationRouter.attentionRequest?.id) {
                handleAttentionRequest()
            }
        } else {
            ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
        }
    }

    private func projectContent(project: Project, runtime: RuntimeSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(project: project, runtime: runtime)
                    ProjectEditorView(
                        project: project,
                        runtime: runtime,
                        attentionRequest: editorAttentionRequest,
                        selection: $selection,
                        isDirty: $editorIsDirty
                    )
                    .frame(minHeight: 430)
                    logPanel(runtime: runtime)
                        .id("projectRuntimeSurface")
                }
                .padding(24)
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                let destination: String
                let anchor: UnitPoint
                switch request.target {
                case .field(let field):
                    destination = "projectField-\(field.rawValue)"
                    anchor = .center
                case .doctor:
                    destination = "projectDoctorSurface"
                    anchor = .center
                case .runtime:
                    destination = "projectRuntimeSurface"
                    anchor = .top
                }
                if reduceMotion {
                    proxy.scrollTo(destination, anchor: anchor)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(destination, anchor: anchor)
                    }
                }
            }
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
                .disabled(
                    !appModel.runtimeControlsAvailable
                        || runtime.status.isActive
                        || runtime.ownership.hasUnresolvedRun
                )
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
            canStart: appModel.runtimeControlsAvailable
                && !runtime.status.isActive
                && !runtime.ownership.hasUnresolvedRun
                && !editorIsDirty,
            canStop: appModel.runtimeControlsAvailable
                && runtime.status.isActive
                && canSignal(runtime),
            canRestart: appModel.runtimeControlsAvailable
                && canSignal(runtime)
                && canRestart(runtime.status)
                && !editorIsDirty,
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

    private func togglePreview() {
        if previewState.isVisible {
            previewState.close()
            return
        }
        guard let project = appModel.project(id: projectID),
              appModel.runtime(for: projectID).status == .ready,
              !editorIsDirty,
              let url = LocalURLValidator().url(from: project.url) else { return }
        previewState.open(url)
    }

    private func handleAttentionRequest() {
        guard let request = appModel.navigationRouter.attentionRequest,
              case .project(let requestedProjectID, let surface) = request.target,
              requestedProjectID == projectID else { return }

        switch surface {
        case .preview:
            if let project = appModel.project(id: projectID),
               appModel.runtime(for: projectID).status == .ready,
               !editorIsDirty,
               let url = LocalURLValidator().url(from: project.url) {
                previewState.open(url)
            }
        case .runtime:
            scrollRequest = ProjectScrollRequest(id: request.id, target: .runtime)
        case .field(let field):
            editorAttentionRequest = request
            scrollRequest = ProjectScrollRequest(
                id: request.id,
                target: field == .dependencies ? .doctor : .field(field)
            )
        case .doctor:
            editorAttentionRequest = request
            scrollRequest = ProjectScrollRequest(id: request.id, target: .doctor)
        }
        appModel.navigationRouter.consumeAttentionRequest(id: request.id)
    }

    private func canRestart(_ status: RuntimeStatus) -> Bool {
        status != .starting && status != .stopping
    }

    private func canSignal(_ runtime: RuntimeSnapshot) -> Bool {
        runtime.ownership == .none || runtime.ownership.permitsSignalling
    }
}

private struct ProjectScrollRequest: Equatable {
    let id: UUID
    let target: ProjectScrollTarget
}

private enum ProjectScrollTarget: Equatable {
    case field(ProjectField)
    case doctor
    case runtime
}
