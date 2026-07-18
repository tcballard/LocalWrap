import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selection: AppSelection?
    @State private var target: WorkspaceTarget
    @State private var importing = false
    @State private var exporting = false
    @State private var reviewedPack: ReviewedWorkspacePack?
    @State private var exportRoot: URL?
    @State private var confirmOverwrite = false
    @State private var editingProfile = false
    @State private var profileName = ""
    @State private var profileProjectIDs = Set<String>()

    init(selection: Binding<AppSelection?>, initialTarget: WorkspaceTarget?) {
        _selection = selection
        _target = State(initialValue: initialTarget ?? .allProjects)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace").font(.largeTitle.bold())
                        Text("Diagnose and start dependency stacks predictably.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Target", selection: $target) {
                        Text("All Projects").tag(WorkspaceTarget.allProjects)
                        if !appModel.workspace.lastRunningProjectIds.isEmpty {
                            Text("Last Running").tag(WorkspaceTarget.lastRunning)
                        }
                        ForEach(appModel.workspace.savedWorkspaces) { profile in
                            Text(profile.name).tag(WorkspaceTarget.profile(profile.id))
                        }
                    }
                    .frame(width: 220)
                    .accessibilityIdentifier("workspaceTargetPicker")
                }

                HStack(spacing: 10) {
                    Button("Resume") { run(.lastRunning, readyOnly: false) }
                        .disabled(appModel.workspace.lastRunningProjectIds.isEmpty || appModel.isWorkspaceOperating)
                        .accessibilityIdentifier("resumeWorkspaceButton")
                    Button("Start Ready") { run(target, readyOnly: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStartReady || appModel.isWorkspaceOperating)
                        .accessibilityIdentifier("startReadyWorkspaceButton")
                    Button("Start All") { run(target, readyOnly: false) }
                        .disabled(appModel.projects.isEmpty || appModel.isWorkspaceOperating)
                        .accessibilityIdentifier("startAllWorkspaceButton")
                    Button("Stop All") { Task { await appModel.stopAllProjects() } }
                        .disabled(appModel.runningProjectCount == 0 && !appModel.isWorkspaceOperating)
                        .accessibilityIdentifier("stopAllWorkspaceButton")
                    Spacer()
                    Button("Create / Update Workspace") { prepareProfileEditor() }
                        .disabled(appModel.projects.isEmpty || appModel.isWorkspaceOperating)
                    Button("Import Workspace") { importing = true }
                        .accessibilityIdentifier("importWorkspaceButton")
                    Button("Export Workspace") { exporting = true }
                        .disabled(appModel.projects.isEmpty)
                        .accessibilityIdentifier("exportWorkspaceButton")
                }

                if appModel.isWorkspaceOperating {
                    ProgressView("Running workspace operation…")
                        .accessibilityIdentifier("workspaceOperationProgress")
                }
                if let diagnosis = appModel.workspaceDiagnosis {
                    HStack(spacing: 18) {
                        metric("Projects", diagnosis.totals.projects)
                        metric("Ready", diagnosis.totals.ready)
                        metric("Warnings", diagnosis.totals.warnings)
                        metric("Blocked", diagnosis.totals.blockers)
                    }
                    WorkspaceDoctorPanelView(diagnosis: diagnosis) { id in
                        selection = .project(id)
                    }
                    .id(WorkspaceDoctorSessionID(diagnosis.target))
                }
                if let operation = appModel.workspaceOperation {
                    WorkspaceOperationResultsView(summary: operation)
                }
            }
            .padding(28)
        }
        .navigationTitle("Workspace")
        .onAppear { appModel.diagnoseWorkspace(target: target) }
        .onChange(of: target) { _, value in appModel.diagnoseWorkspace(target: value) }
        .focusedValue(\.workspaceCommandActions, WorkspaceCommandActions(
            canStart: !appModel.projects.isEmpty && !appModel.isWorkspaceOperating,
            canStop: appModel.runningProjectCount > 0 || appModel.isWorkspaceOperating,
            startReady: { run(target, readyOnly: true) },
            startAll: { run(target, readyOnly: false) },
            stopAll: { Task { await appModel.stopAllProjects() } }
        ))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            do { reviewedPack = try appModel.reviewWorkspacePack(rootURL: result.get()) }
            catch { appModel.errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            do {
                let root = try result.get()
                exportRoot = root
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(".localwrap/workspace.json").path) {
                    confirmOverwrite = true
                } else {
                    _ = appModel.exportWorkspacePack(rootURL: root, overwrite: false)
                }
            } catch { appModel.errorMessage = error.localizedDescription }
        }
        .confirmationDialog("Replace existing workspace pack?", isPresented: $confirmOverwrite) {
            Button("Replace", role: .destructive) {
                if let exportRoot { _ = appModel.exportWorkspacePack(rootURL: exportRoot, overwrite: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $reviewedPack) { pack in
            WorkspacePackReviewView(pack: pack) { appModel.importWorkspacePack(pack) }
        }
        .sheet(isPresented: $editingProfile) {
            profileEditor
        }
    }

    private var canStartReady: Bool {
        !(appModel.workspaceDiagnosis?.startableProjectIDs.isEmpty ?? true)
    }

    private func run(_ target: WorkspaceTarget, readyOnly: Bool) {
        Task { await appModel.startWorkspace(target: target, readyOnly: readyOnly) }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func prepareProfileEditor() {
        if case .profile(let id) = target,
           let profile = appModel.workspace.savedWorkspaces.first(where: { $0.id == id }) {
            profileName = profile.name
            profileProjectIDs = Set(profile.projectIds)
        } else {
            profileName = ""
            profileProjectIDs = Set(appModel.workspaceDiagnosis?.target.projectIDs ?? appModel.projects.map(\.id))
        }
        editingProfile = true
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Workspace").font(.title2.bold())
            TextField("Workspace name", text: $profileName)
            List(appModel.projects) { project in
                Toggle(project.name, isOn: Binding(
                    get: { profileProjectIDs.contains(project.id) },
                    set: { enabled in
                        if enabled { profileProjectIDs.insert(project.id) }
                        else { profileProjectIDs.remove(project.id) }
                    }
                ))
            }
            HStack {
                Spacer()
                Button("Cancel") { editingProfile = false }
                Button("Save") {
                    let existingID = target.profileID
                    if let saved = appModel.saveWorkspaceProfile(
                        id: existingID,
                        name: profileName,
                        projectIDs: appModel.projects.map(\.id).filter(profileProjectIDs.contains)
                    ) {
                        target = .profile(saved.id)
                        selection = .workspace(target)
                    }
                    editingProfile = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profileProjectIDs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 500)
    }
}

extension ReviewedWorkspacePack: Identifiable {
    var id: String { packURL.path }
}

private struct WorkspaceDoctorSessionID: Hashable {
    let kind: String
    let profileID: String?
    let projectIDs: [String]

    init(_ target: ResolvedWorkspaceTarget) {
        kind = target.kind.rawValue
        profileID = target.profileID
        projectIDs = target.projectIDs
    }
}
